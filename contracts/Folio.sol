// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { IFolio } from "./interfaces/IFolio.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IFolioFeeRegistry } from "./interfaces/IFolioFeeRegistry.sol";
// import { FolioDutchTrade, TradePrices } from "./FolioDutchTrade.sol";

import "forge-std/console2.sol";

contract Folio is IFolio, ERC20 {
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant BPS_PRECISION = 100_00;
    uint256 public constant TRADE_PRECISION = 1e18;
    uint256 public constant MAX_DEMURRAGE_FEE = 5000;
    uint256 public constant YEAR_IN_SECONDS = 60 * 60 * 24 * 365;

    address public owner;
    IFolioFeeRegistry public daoFeeRegistry;

    EnumerableSet.AddressSet private basket;
    bool public basketInitialized;

    DemurrageRecipient[] public demurrageRecipients;
    uint256 public demurrageFee; // bps

    address public dutchTradeImplementation;
    uint256 public dutchAuctionLength; // {s}

    // Trade[] public trades;

    uint40 public lastPoke; // {s}
    uint256 public pendingFeeShares;

    constructor(
        string memory name,
        string memory symbol,
        uint256 _demurrageFee,
        DemurrageRecipient[] memory _demurrageRecipients,
        address _daoFeeRegistry,
        address _dutchTradeImplementation
    ) ERC20(name, symbol) {
        _setDemurrageFee(_demurrageFee);
        _setDemurrageRecipients(_demurrageRecipients);
        dutchTradeImplementation = _dutchTradeImplementation;
        daoFeeRegistry = IFolioFeeRegistry(_daoFeeRegistry);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert("only owner can call this function");
        }
        _;
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
    }

    function initialize(address[] memory _assets, address initializer, uint256 shares) external onlyOwner {
        if (basketInitialized) {
            revert("basket already initialized");
        }

        uint256 len = _assets.length;
        for (uint256 i; i < len; i++) {
            if (_assets[i] == address(0)) {
                revert("asset cannot be 0");
            }

            uint256 bal = IERC20(_assets[i]).balanceOf(address(this));
            if (bal == 0) {
                revert("amount cannot be 0");
            }

            basket.add(address(_assets[i]));
        }

        _mint(initializer, shares);
        basketInitialized = true;
    }

    function totalSupply() public view virtual override(ERC20) returns (uint256) {
        return super.totalSupply() + pendingFeeShares;
    }

    function assets() external view returns (address[] memory _assets) {
        return basket.values();
    }

    // ( {tokAddress}, {tok/share} )
    function folio() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        return convertToAssets(1e18, Math.Rounding.Down);
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
        Math.Rounding rounding
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
        (_assets, _amounts) = convertToAssets(shares, Math.Rounding.Down);
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
        (_assets, _amounts) = convertToAssets(shares, Math.Rounding.Down);

        if (msg.sender != holder) {
            _spendAllowance(holder, msg.sender, shares);
        }
        _burn(holder, shares);

        uint256 len = _assets.length;
        for (uint256 i; i < len; i++) {
            IERC20(_assets[i]).transfer(receiver, _amounts[i]);
        }
    }

    function setDemurrageFee(uint256 _demurrageFee) external onlyOwner {
        distributeFees();
        _setDemurrageFee(_demurrageFee);
    }

    function setDemurrageRecipients(DemurrageRecipient[] memory _demurrageRecipients) external onlyOwner {
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
        return ((supply * (demurrageFee * timeDelta)) / YEAR_IN_SECONDS) / BPS_PRECISION;
    }

    /// @dev updates the internal state by minting demurrage shares
    function _poke() internal {
        if (lastPoke == block.timestamp) {
            return;
        }
        uint256 demFee = _getPendingFeeShares();
        pendingFeeShares += demFee;
        lastPoke = uint40(block.timestamp);
    }

    function _setDemurrageFee(uint256 _demurrageFee) internal {
        if (_demurrageFee > MAX_DEMURRAGE_FEE) {
            revert Folio_badDemurrageFee();
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

    function _beforeTokenTransfer(address, address, uint256) internal virtual override {
        _poke();
    }
}