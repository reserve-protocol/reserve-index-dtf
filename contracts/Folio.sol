// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IFolioFeeRegistry } from "./interfaces/IFolioFeeRegistry.sol";
import { IFolio } from "./interfaces/IFolio.sol";

// !!!! TODO !!!! REMOVE
import "forge-std/console2.sol";

uint256 constant BPS_PRECISION = 100_00;
uint256 constant MAX_DEMURRAGE_FEE = 50_00;

contract Folio is IFolio, ERC20, AccessControlEnumerable {
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    IFolioFeeRegistry public daoFeeRegistry;

    /**
     * Roles
     */
    bytes32 constant PRICE_ORACLE = keccak256("PRICE_ORACLE");

    /**
     * Basket
     */
    bool public basketInitialized; // @audit Do we need this? Non-zero length basket should be enough
    EnumerableSet.AddressSet private basket;

    /**
     * Fees
     */
    DemurrageRecipient[] public demurrageRecipients;
    uint256 public demurrageFee; // bps

    /**
     * System
     */
    uint256 public lastPoke; // {s}
    uint256 public pendingFeeShares;

    address public dutchTradeImplementation;
    uint256 public dutchAuctionLength; // {s}

    // Trade[] public trades;

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _demurrageFee,
        DemurrageRecipient[] memory _demurrageRecipients,
        address _daoFeeRegistry,
        address _dutchTradeImplementation
    ) ERC20(_name, _symbol) {
        _setDemurrageFee(_demurrageFee);
        _setDemurrageRecipients(_demurrageRecipients);

        daoFeeRegistry = IFolioFeeRegistry(_daoFeeRegistry);
        dutchTradeImplementation = _dutchTradeImplementation;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function initialize(
        address[] memory _assets,
        address initializer,
        uint256 shares
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (basketInitialized) {
            revert Folio__BasketAlreadyInitialized();
        }

        uint256 assetLength = _assets.length;
        for (uint256 i; i < assetLength; i++) {
            if (_assets[i] == address(0)) {
                revert("asset cannot be 0");
            }

            uint256 bal = IERC20(_assets[i]).balanceOf(address(this));
            if (bal == 0) {
                revert("amount cannot be 0");
            }

            basket.add(address(_assets[i]));
        }

        basketInitialized = true;

        _mint(initializer, shares);
    }

    function totalSupply() public view virtual override(ERC20) returns (uint256) {
        return super.totalSupply() + pendingFeeShares;
    }

    function assets() external view returns (address[] memory _assets) {
        return basket.values();
    }

    // ( {tokAddress}, {tok/share} )
    function folio() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        return convertToAssets(1e18, Math.Rounding.Floor);
    }

    // ( {tokAddress}, {tok} )
    function totalAssets() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        _assets = basket.values();
        uint256 len = _assets.length;
        _amounts = new uint256[](len);
        for (uint256 i; i < len; i++) {
            _amounts[i] = IERC20(_assets[i]).balanceOf(address(this));
        }
    }

    // {share} -> ( {tokAddress}, {tok} )
    function convertToAssets(
        uint256 shares,
        Math.Rounding rounding // @audit TODO: Make explicit, should not be an external facing detail
    ) public view returns (address[] memory _assets, uint256[] memory _amounts) {
        _assets = basket.values();

        uint256 len = _assets.length;
        _amounts = new uint256[](len);
        for (uint256 i; i < len; i++) {
            uint256 assetBal = IERC20(_assets[i]).balanceOf(address(this));
            _amounts[i] = shares.mulDiv(assetBal + 1, totalSupply(), rounding);
        }
    }

    // {share} -> ( {tokAddress}, {tok} )
    function mint(
        uint256 shares,
        address receiver
    ) external returns (address[] memory _assets, uint256[] memory _amounts) {
        (_assets, _amounts) = convertToAssets(shares, Math.Rounding.Floor);
        _mint(receiver, shares);

        uint256 len = _assets.length;
        for (uint256 i; i < len; i++) {
            IERC20(_assets[i]).transferFrom(msg.sender, address(this), _amounts[i]);
        }
    }

    // {share} -> ( {tokAddress}, {tok} )
    function redeem(
        uint256 shares,
        address receiver,
        address holder
    ) external returns (address[] memory _assets, uint256[] memory _amounts) {
        (_assets, _amounts) = convertToAssets(shares, Math.Rounding.Floor);

        if (msg.sender != holder) {
            _spendAllowance(holder, msg.sender, shares);
        }
        _burn(holder, shares);

        uint256 len = _assets.length;
        for (uint256 i; i < len; i++) {
            IERC20(_assets[i]).transfer(receiver, _amounts[i]);
        }
    }

    function setDemurrageFee(uint256 _demurrageFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setDemurrageFee(_demurrageFee);
    }

    function setDemurrageRecipients(
        DemurrageRecipient[] memory _demurrageRecipients
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setDemurrageRecipients(_demurrageRecipients);
    }

    function distributeFees() public {
        _poke();

        // collect dao fee off the top
        (address recipient, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(
            address(this)
        );
        uint256 daoFee = (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        _mint(recipient, daoFee);
        pendingFeeShares -= daoFee;

        // distribute the rest of the demurrage fee
        uint256 len = demurrageRecipients.length;
        for (uint256 i; i < len; i++) {
            uint256 fee = (pendingFeeShares * demurrageRecipients[i].bps) / BPS_PRECISION;
            _mint(demurrageRecipients[i].recipient, fee);
        }
        pendingFeeShares = 0;
    }

    function poke() external {
        _poke();
    }

    function getPendingFeeShares() public view returns (uint256) {
        return pendingFeeShares + _getPendingFeeShares();
    }

    // function approveTrade(TradeParams memory trade) external {
    //     if (trade.amount == 0) {
    //         revert("trade.amount cannot be 0");
    //     }
    //     if (trade.from == address(0) || trade.to == address(0)) {
    //         revert("trade.from or trade.to cannot be 0");
    //     }
    //     if (trade.from == trade.to) {
    //         revert("trade.from and trade.to cannot be the same");
    //     }
    //     if (!basket.contains(trade.from)) {
    //         revert("trade.from is not in basket");
    //     }

    //     trades.push(new Trade(trade, address(0)));

    //     emit TradeApproved(trades.length, trade.sell, trade.buy, trade.amount);
    // }
    // function launchTrade(uint256 _tradeId, TradePrices memory prices) external {
    //     poke();
    //     FolioDutchTrade trader = FolioDutchTrade(address(dutchTradeImplementation).clone());
    //     Trade storage trade = trades[_tradeId];
    //     trades.trader = trader;
    //     IERC20(address(trade.sell)).safeTransfer(address(trade), trade.amount);
    //     trade.init(address(this), trade.sell, trade.buy, trade.amount, dutchAuctionLength, prices);
    //     emit TradeLaunched(_tradeId);
    // }
    // function forceSettleTrade(uint256 _tradeId) external {
    //     poke();
    //     Trade memory trade = trades[_tradeId];
    //     trade.trader.settle();
    // }
    // function settleTrade(uint256 _tradeId) external {
    //     poke();
    //     Trade memory trade = trades[_tradeId];
    //     if (msg.sender != address(trade.trader)) {
    //         revert("only trader can settle");
    //     }
    //     if (!basket.contains(trade.to)) {
    //         basket.add(trade.to);
    //     }
    //     (uint256 soldAmount, uint256 boughtAmount) = trade.trader.settle();
    //     emit TradeSettled(_tradeId, boughtAmount);
    // }

    /*
        Internal functions
    */

    function _getPendingFeeShares() internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 timeDelta = block.timestamp - lastPoke;

        return ((supply * (demurrageFee * timeDelta)) / 365 days) / BPS_PRECISION;
    }

    /// @dev updates the internal state by minting demurrage shares
    function _poke() internal {
        if (lastPoke == block.timestamp) {
            return;
        }

        pendingFeeShares += _getPendingFeeShares();
        lastPoke = block.timestamp;
    }

    function _setDemurrageFee(uint256 _demurrageFee) internal {
        if (_demurrageFee > MAX_DEMURRAGE_FEE) {
            revert Folio__DemurrageFeeTooHigh();
        }

        demurrageFee = _demurrageFee;
    }

    function _setDemurrageRecipients(DemurrageRecipient[] memory _demurrageRecipients) internal {
        // clear out demurrageRecipients
        uint256 len = demurrageRecipients.length;
        for (uint256 i; i < len; i++) {
            demurrageRecipients.pop();
        }

        // validate that amounts add up to BPS_PRECISION
        uint256 total;
        len = _demurrageRecipients.length;
        for (uint256 i; i < len; i++) {
            if (_demurrageRecipients[i].recipient == address(0)) {
                revert Folio_badDemurrageFeeRecipientAddress();
            }

            if (_demurrageRecipients[i].bps == 0) {
                revert Folio_badDemurrageFeeRecipientBps();
            }

            total += _demurrageRecipients[i].bps;
            demurrageRecipients.push(_demurrageRecipients[i]);
        }

        if (total != BPS_PRECISION) {
            revert Folio_badDemurrageFeeTotal();
        }
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        _poke();

        super._update(from, to, value);
    }
}
