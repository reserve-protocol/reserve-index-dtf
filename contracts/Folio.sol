// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { UD60x18, powu } from "@prb/math/src/UD60x18.sol";
import { SD59x18, exp, intoUint256 } from "@prb/math/src/SD59x18.sol";

import { Versioned } from "@utils/Versioned.sol";

import { IFolioDAOFeeRegistry } from "./interfaces/IFolioDAOFeeRegistry.sol";
import { IFolio } from "./interfaces/IFolio.sol";

// !!!! TODO !!!! REMOVE
import "forge-std/console2.sol";

interface IBidderCallee {
    /// @param buyAmount {qBuyTok}
    function bidCallback(address buyToken, uint256 buyAmount, bytes calldata data) external;
}

uint256 constant MAX_FEE = 21979552668; // D18{1/s} 50% annually
uint256 constant MIN_AUCTION_LENGTH = 60; // {s} 1 min
uint256 constant MAX_AUCTION_LENGTH = 604800; // {s} 1 week

// TODO go through and see if we can remove any of the nonReentrant modifiers

contract Folio is
    IFolio,
    Initializable,
    ERC20Upgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    Versioned
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    IFolioDAOFeeRegistry public daoFeeRegistry;

    /**
     * Roles
     */
    bytes32 public constant TRADE_PROPOSER = keccak256("TRADE_PROPOSER"); // expected to be trading governance
    bytes32 public constant PRICE_CURATOR = keccak256("PRICE_CURATOR"); // expected to be the trading timelock + optional EOA

    /**
     * Basket
     */
    EnumerableSet.AddressSet private basket;

    /**
     * Fees
     */
    FeeRecipient[] public feeRecipients;
    uint256 public folioFee; // D18{1} demurrage fee on AUM

    /**
     * System
     */
    uint256 public lastPoke; // {s}
    uint256 public pendingFeeShares; // {share} virtual shares part of supply; use getPendingFeeShares() externally

    /**
     * Trading
     *   - Multiple trades can be open at once
     *   - Multiple bids can be executed against the same trade
     *   - All trades are dutch auctions, but it's possible to pass startPrice = endPrice
     */

    uint256 public auctionLength; // {s}
    Trade[] public trades;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        FolioBasicDetails calldata basicDetails,
        FolioAdditionalDetails calldata additionalDetails
    ) external initializer {
        __ERC20_init(basicDetails.name, basicDetails.symbol);
        __AccessControlEnumerable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _setFeeRecipients(additionalDetails.feeRecipients);
        _setFolioFee(additionalDetails.folioFee);
        _setAuctionLength(additionalDetails.auctionLength);

        daoFeeRegistry = IFolioDAOFeeRegistry(additionalDetails.feeRegistry);

        uint256 assetLength = basicDetails.assets.length;
        for (uint256 i; i < assetLength; i++) {
            if (basicDetails.assets[i] == address(0)) {
                revert Folio__InvalidAsset();
            }

            uint256 assetBalance = IERC20(basicDetails.assets[i]).balanceOf(address(this));
            if (assetBalance == 0) {
                revert Folio__InvalidAssetAmount(basicDetails.assets[i]);
            }

            basket.add(address(basicDetails.assets[i]));
        }

        _poke();
        _mint(basicDetails.creator, basicDetails.initialShares);
        _grantRole(DEFAULT_ADMIN_ROLE, basicDetails.governor);
    }

    function poke() external nonReentrant {
        _poke();
    }

    // ==== Governance ====

    function addToBasket(IERC20 token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        basket.add(address(token));
    }

    function removeFromBasket(IERC20 token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        basket.remove(address(token));
    }

    function setFolioFee(uint256 _newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setFolioFee(_newFee);
    }

    /// _newRecipients.portion must sum to 1e18
    function setFeeRecipients(FeeRecipient[] memory _newRecipients) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setFeeRecipients(_newRecipients);
    }

    function setAuctionLength(uint256 _newLength) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAuctionLength(_newLength);
    }

    // ==== Share + Asset Accounting ====

    function totalSupply() public view virtual override(ERC20Upgradeable) returns (uint256) {
        return super.totalSupply() + _getPendingFeeShares();
    }

    // {} -> ({tokAddress}, {tok/share})
    function folio() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        return toAssets(10 ** decimals(), Math.Rounding.Floor);
    }

    // {} -> ({tokAddress}, {tok})
    function totalAssets() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        _assets = basket.values();

        uint256 assetLength = _assets.length;
        _amounts = new uint256[](assetLength);
        for (uint256 i; i < assetLength; i++) {
            _amounts[i] = IERC20(_assets[i]).balanceOf(address(this));
        }
    }

    // {share} -> ({tokAddress}, {tok})
    function toAssets(
        uint256 shares,
        Math.Rounding rounding
    ) public view returns (address[] memory _assets, uint256[] memory _amounts) {
        uint256 _totalSupply = totalSupply();

        _assets = basket.values();

        uint256 len = _assets.length;
        _amounts = new uint256[](len);
        for (uint256 i; i < len; i++) {
            uint256 assetBal = IERC20(_assets[i]).balanceOf(address(this));

            _amounts[i] = Math.mulDiv(shares, assetBal, _totalSupply, rounding);
        }
    }

    // {share} -> ({tokAddress}, {tok})
    function mint(
        uint256 shares,
        address receiver
    ) external nonReentrant returns (address[] memory _assets, uint256[] memory _amounts) {
        _poke();

        (_assets, _amounts) = toAssets(shares, Math.Rounding.Ceil);

        uint256 assetLength = _assets.length;
        for (uint256 i; i < assetLength; i++) {
            SafeERC20.safeTransferFrom(IERC20(_assets[i]), msg.sender, address(this), _amounts[i]);
        }

        _mint(receiver, shares);
    }

    // {share} -> ({tokAddress}, {tok})
    function redeem(
        uint256 shares,
        address receiver
    ) external nonReentrant returns (address[] memory _assets, uint256[] memory _amounts) {
        _poke();

        (_assets, _amounts) = toAssets(shares, Math.Rounding.Floor);

        _burn(msg.sender, shares);

        uint256 len = _assets.length;
        for (uint256 i; i < len; i++) {
            SafeERC20.safeTransfer(IERC20(_assets[i]), receiver, _amounts[i]);
        }
    }

    // === Fee Shares ===

    function distributeFees() public nonReentrant {
        _poke();
        // pendingFeeShares is up-to-date

        // collect dao fee off the top
        (address recipient, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(
            address(this)
        );
        uint256 daoFee = (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        _mint(recipient, daoFee);
        pendingFeeShares -= daoFee;

        // distribute the rest of the folioFee
        uint256 len = feeRecipients.length;
        for (uint256 i; i < len; i++) {
            // {share} = {share} * D18{1} / D18
            uint256 share = (pendingFeeShares * feeRecipients[i].portion) / 1e18;

            _mint(feeRecipients[i].recipient, share);
        }

        pendingFeeShares = 0;
    }

    function getPendingFeeShares() public view returns (uint256) {
        return _getPendingFeeShares();
    }

    // ==== Trading ====

    /// @param tradeId Used to ensure expected ordering
    /// @param sell The token to sell, from the perspective of the Folio
    /// @param buy The token to buy, from the perspective of the Folio
    /// @param sellAmount {sellTok} Provide type(uint256).max to sell everything
    /// @param startPrice D18{buyTok/sellTok} Provide 0 to defer pricing to price curator
    /// @param endPrice D18{buyTok/sellTok} Provide 0 to defer pricing to price curator
    /// @param ttl {s} How long trade can be opened (once opened, it always finishes). Accepts type(uint256).max
    function approveTrade(
        uint256 tradeId,
        IERC20 sell,
        IERC20 buy,
        uint256 sellAmount,
        uint256 startPrice,
        uint256 endPrice,
        uint256 ttl
    ) external nonReentrant onlyRole(TRADE_PROPOSER) {
        if (trades.length != tradeId) {
            revert Folio__InvalidTradeId();
        }

        if (address(sell) == address(0) || address(buy) == address(0)) {
            revert Folio__InvalidTradeTokens();
        }

        if (sellAmount == 0) {
            revert Folio__InvalidSellAmount();
        }

        uint256 launchTimeout = ttl == type(uint256).max ? ttl : block.timestamp + ttl;

        trades.push(
            Trade({
                id: trades.length,
                sell: sell,
                buy: buy,
                sellAmount: sellAmount,
                startPrice: startPrice,
                endPrice: endPrice,
                launchTimeout: launchTimeout,
                start: 0,
                end: 0
            })
        );
        emit TradeApproved(tradeId, address(sell), address(buy), sellAmount, startPrice);
    }

    /// @param startPrice D18{buyTok/sellTok}
    /// @param endPrice D18{buyTok/sellTok}
    function openTrade(
        uint256 tradeId,
        uint256 startPrice,
        uint256 endPrice
    ) external nonReentrant onlyRole(PRICE_CURATOR) {
        Trade storage trade = trades[tradeId];

        if (trade.start != 0 || trade.end != 0) {
            revert Folio__TradeCannotBeOpened();
        }

        if (block.timestamp > trade.launchTimeout) {
            revert Folio__TradeTimeout();
        }

        if (
            startPrice == 0 ||
            startPrice < trade.startPrice ||
            (trade.startPrice > 0 && startPrice > 100 * trade.startPrice)
        ) {
            revert Folio__InvalidStartPrice();
        }

        if (endPrice == 0 || endPrice < trade.endPrice || startPrice < endPrice) {
            revert Folio__InvalidEndPrice();
        }

        if (trade.sellAmount != type(uint256).max && trade.sell.balanceOf(address(this)) < trade.sellAmount) {
            revert Folio__InsufficientBalance();
        }

        trade.startPrice = startPrice;
        trade.endPrice = endPrice;
        trade.start = block.timestamp;
        trade.end = block.timestamp + auctionLength;
        emit TradeOpened(tradeId, startPrice, endPrice, block.timestamp, block.timestamp + auctionLength);
    }

    /// @return D18{buyTok/sellTok}
    function getPrice(uint256 tradeId, uint256 timestamp) external view returns (uint256) {
        return _price(trades[tradeId], timestamp);
    }

    /// @return {buyTok} The amount the bidder would receive
    function getBidAmount(uint256 tradeId, uint256 amount, uint256 timestamp) external view returns (uint256) {
        uint256 price = _price(trades[tradeId], timestamp);
        return (amount * price + 1e18 - 1) / 1e18;
    }

    /// Bid in an ongoing auction
    ///   If withCallback is true, caller must adhere to IBidderCallee interface and receives a callback
    ///   If withCallback is false, caller must have provided an allowance in advance
    /// @dev Permissionless
    /// @param sellAmount {sellTok} Token the bidder receives, sold from the point of view of the Folio
    /// @param maxBuyAmount {buyTok} Token the bidder provides, bought from the point of view of the Folio
    /// @param withCallback If true, caller must adhere to IBidderCallee interface and transfers tokens via callback
    /// @param data Arbitrary data to pass to the callback
    function bid(
        uint256 tradeId,
        uint256 sellAmount,
        uint256 maxBuyAmount,
        bool withCallback,
        bytes calldata data
    ) external nonReentrant returns (uint256 boughtAmt) {
        Trade storage trade = trades[tradeId];

        // checks trade is ongoing
        uint256 price = _price(trade, block.timestamp);

        // {buyTok} = {sellTok} * D18{buyTok/sellTok} / D18
        boughtAmt = (sellAmount * price + 1e18 - 1) / 1e18;
        if (boughtAmt > maxBuyAmount) {
            revert Folio__SlippageExceeded();
        }

        if (trade.sellAmount != type(uint256).max) {
            trade.sellAmount -= sellAmount;
        }

        basket.add(address(trade.buy));

        if (trade.sell.balanceOf(address(this)) == 0) {
            basket.remove(address(trade.sell));
        }

        trade.sell.safeTransfer(msg.sender, sellAmount);
        emit Bid(tradeId, sellAmount, boughtAmt);

        if (withCallback) {
            IBidderCallee(msg.sender).bidCallback(address(trade.buy), boughtAmt, data);
        } else {
            trade.buy.safeTransferFrom(msg.sender, address(this), boughtAmt);
        }
    }

    /// Kill a trade
    /// A trade can be killed anywhere in its lifecycle, and cannot be restarted
    /// @dev Redundant calls do not revert to prevent griefing
    function killTrade(uint256 tradeId) external nonReentrant onlyRole(PRICE_CURATOR) {
        trades[tradeId].end = 1;
        emit TradeKilled(tradeId);
    }

    // ==== Internal ====

    function _price(Trade storage trade, uint256 timestamp) internal view returns (uint256) {
        if (timestamp < trade.start || timestamp > trade.end || trade.sellAmount == 0) {
            revert Folio__TradeNotOngoing();
        }

        uint256 _auctionLength = trade.end - trade.start;

        // k = ln(P_0 / P_t) / t
        uint256 k = UD60x18.wrap((trade.startPrice * 1e18) / trade.endPrice).ln().unwrap() / _auctionLength;

        uint256 elapsed = timestamp - trade.start;
        // TODO check exp() for overflow
        return (trade.startPrice * intoUint256(exp(SD59x18.wrap(-1 * int256(k * elapsed))))) / 1e18;
    }

    function _getPendingFeeShares() internal view returns (uint256 _pendingFeeShares) {
        _pendingFeeShares = pendingFeeShares;

        uint256 supply = super.totalSupply() + _pendingFeeShares; // slightly stale value
        uint256 elapsed = block.timestamp - lastPoke;

        _pendingFeeShares += (supply * 1e18) / UD60x18.wrap(1e18 - folioFee).powu(elapsed).unwrap() - supply;
    }

    function _setFolioFee(uint256 _newFee) internal {
        if (_newFee > MAX_FEE) {
            revert Folio__FeeTooHigh();
        }

        folioFee = _newFee;
    }

    function _setFeeRecipients(FeeRecipient[] memory _feeRecipients) internal {
        // Clear existing fee table
        uint256 len = feeRecipients.length;
        for (uint256 i; i < len; i++) {
            feeRecipients.pop();
        }

        // Add new items to the fee table
        uint256 total;
        len = _feeRecipients.length;
        for (uint256 i; i < len; i++) {
            if (_feeRecipients[i].recipient == address(0)) {
                revert Folio__FeeRecipientInvalidAddress();
            }

            if (_feeRecipients[i].portion == 0) {
                revert Folio__FeeRecipientInvalidFeeShare();
            }

            total += _feeRecipients[i].portion;
            feeRecipients.push(_feeRecipients[i]);
        }

        if (total != 1e18) {
            revert Folio__BadFeeTotal();
        }
    }

    function _setAuctionLength(uint256 _newLength) internal {
        if (_newLength < MIN_AUCTION_LENGTH || _newLength > MAX_AUCTION_LENGTH) {
            revert Folio__InvalidAuctionLength();
        }

        auctionLength = _newLength;
    }

    /// @dev After: pendingFeeShares is up-to-date
    function _poke() internal {
        if (lastPoke == block.timestamp) {
            return;
        }

        pendingFeeShares = _getPendingFeeShares();
        lastPoke = block.timestamp;
    }
}
