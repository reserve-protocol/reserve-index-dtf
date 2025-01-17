// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { UD60x18, powu, pow } from "@prb/math/src/UD60x18.sol";
import { SD59x18, exp, intoUint256 } from "@prb/math/src/SD59x18.sol";

import { Versioned } from "@utils/Versioned.sol";

import { IFolioDAOFeeRegistry } from "@interfaces/IFolioDAOFeeRegistry.sol";
import { IFolio } from "@interfaces/IFolio.sol";

interface IBidderCallee {
    /// @param buyAmount {qBuyTok}
    function bidCallback(address buyToken, uint256 buyAmount, bytes calldata data) external;
}

uint256 constant MAX_FOLIO_FEE = 0.5e18; // D18{1/year} 50% annually
uint256 constant MAX_MINTING_FEE = 0.10e18; // D18{1} 10%
uint256 constant MIN_AUCTION_LENGTH = 60; // {s} 1 min
uint256 constant MAX_AUCTION_LENGTH = 604800; // {s} 1 week
uint256 constant MAX_TRADE_DELAY = 604800; // {s} 1 week
uint256 constant MAX_FEE_RECIPIENTS = 64;
uint256 constant MAX_TTL = 604800 * 4; // {s} 4 weeks
uint256 constant MIN_DAO_MINTING_FEE = 0.0005e18; // D18{1} 5 bps
uint256 constant MAX_RATE = 1e54; // D18{buyTok/sellTok}
uint256 constant MAX_PRICE_RANGE = 1e9; // {1}

UD60x18 constant ANNUALIZATION_EXP = UD60x18.wrap(31709791983); // D18{1/s} 1 / 31536000

uint256 constant D18 = 1e18; // D18
uint256 constant D27 = 1e27; // D27

/**
 * @title Folio
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 */
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
    bytes32 public constant TRADE_PROPOSER = keccak256("TRADE_PROPOSER"); // expected to be trading governance's timelock
    bytes32 public constant TRADE_LAUNCHER = keccak256("TRADE_LAUNCHER"); // optional: EOA or multisig
    bytes32 public constant VIBES_OFFICER = keccak256("VIBES_OFFICER"); // optional: no permissions

    /**
     */
    EnumerableSet.AddressSet private basket;

    /**
     * Fees
     */
    FeeRecipient[] public feeRecipients;
    uint256 public folioFee; // D18{1/s} demurrage fee on AUM
    uint256 public mintingFee; // D18{1} fee on mint

    /**
     * System
     */
    uint256 public lastPoke; // {s}
    uint256 public daoPendingFeeShares; // {share} shares pending to be distributed ONLY to the DAO
    uint256 public feeRecipientsPendingFeeShares; // {share} shares pending to be distributed ONLY to fee recipients
    bool public isKilled; // {bool} If true, Folio goes into redemption-only mode

    /**
     * Trading
     *   - Trades have a delay before they can be opened, that TRADE_LAUNCHER can bypass
     *   - Multiple trades can be open at once
     *   - Multiple bids can be executed against the same trade
     *   - All trades are dutch auctions, but it's possible to pass startPrice = endPrice
     */
    uint256 public auctionLength; // {s}
    uint256 public tradeDelay; // {s}
    Trade[] public trades;
    mapping(address => uint256) public sellEnds; // {s}
    mapping(address => uint256) public buyEnds; // {s}

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        FolioBasicDetails calldata _basicDetails,
        FolioAdditionalDetails calldata _additionalDetails,
        address _creator,
        address _daoFeeRegistry
    ) external initializer {
        __ERC20_init(_basicDetails.name, _basicDetails.symbol);
        __AccessControlEnumerable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _setFeeRecipients(_additionalDetails.feeRecipients);
        _setFolioFee(_additionalDetails.folioFee);
        _setMintingFee(_additionalDetails.mintingFee);
        _setTradeDelay(_additionalDetails.tradeDelay);
        _setAuctionLength(_additionalDetails.auctionLength);

        daoFeeRegistry = IFolioDAOFeeRegistry(_daoFeeRegistry);

        uint256 assetLength = _basicDetails.assets.length;
        if (assetLength == 0) {
            revert Folio__EmptyAssets();
        }

        for (uint256 i; i < assetLength; i++) {
            if (_basicDetails.assets[i] == address(0)) {
                revert Folio__InvalidAsset();
            }

            uint256 assetBalance = IERC20(_basicDetails.assets[i]).balanceOf(address(this));
            if (assetBalance == 0) {
                revert Folio__InvalidAssetAmount(_basicDetails.assets[i]);
            }

            emit BasketTokenAdded(_basicDetails.assets[i]);
            basket.add(address(_basicDetails.assets[i]));
        }

        lastPoke = block.timestamp;
        _mint(_creator, _basicDetails.initialShares);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function poke() external nonReentrant {
        _poke();
    }

    // ==== Governance ====

    function addToBasket(IERC20 token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(basket.add(address(token)), Folio__BasketModificationFailed());

        emit BasketTokenAdded(address(token));
    }

    function removeFromBasket(IERC20 token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(basket.remove(address(token)), Folio__BasketModificationFailed());

        emit BasketTokenRemoved(address(token));
    }

    /// @dev Non-reentrant via distributeFees()
    /// @param _newFee D18{1/s} Fee per second on AUM
    function setFolioFee(uint256 _newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setFolioFee(_newFee);
    }

    /// A minting fee below 5 bps will result in the entirety of the fee being sent to the DAO
    /// @dev Non-reentrant via distributeFees()
    /// @param _newFee D18{1} Fee on mint
    function setMintingFee(uint256 _newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setMintingFee(_newFee);
    }

    /// @dev Non-reentrant via distributeFees()
    /// @dev Fee recipients must be unique and sorted by address, and sum to 1e18
    function setFeeRecipients(FeeRecipient[] memory _newRecipients) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setFeeRecipients(_newRecipients);
    }

    /// @param _newDelay {s} Delay after a trade has been approved before it can be permissionlessly opened
    function setTradeDelay(uint256 _newDelay) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTradeDelay(_newDelay);
    }

    /// @param _newLength {s} Length of an auction
    function setAuctionLength(uint256 _newLength) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAuctionLength(_newLength);
    }

    function killFolio() external onlyRole(DEFAULT_ADMIN_ROLE) {
        isKilled = true;

        emit FolioKilled();
    }

    // ==== Share + Asset Accounting ====

    /// @dev Contains all pending fee shares
    function totalSupply() public view virtual override(ERC20Upgradeable) returns (uint256) {
        (uint256 _daoPendingFeeShares, uint256 _feeRecipientsPendingFeeShares) = _getPendingFeeShares();
        return super.totalSupply() + _daoPendingFeeShares + _feeRecipientsPendingFeeShares;
    }

    // {} -> ({tokAddress}, {tok})
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
        if (_reentrancyGuardEntered()) {
            revert ReentrancyGuardReentrantCall();
        }

        return _toAssets(shares, rounding);
    }

    // {share} -> ({tokAddress}, {tok})
    /// @dev Minting has 3 share-portions: (i) receiver shares, (ii) DAO fee shares, (iii) fee recipients shares
    function mint(
        uint256 shares,
        address receiver
    ) external nonReentrant returns (address[] memory _assets, uint256[] memory _amounts) {
        require(!isKilled, Folio__FolioKilled());

        _poke();

        // === Calculate fee shares ===

        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(this));

        // {share} = {share} * D18{1} / D18
        uint256 totalFeeShares = (shares * mintingFee + D18 - 1) / D18;
        uint256 daoFeeShares = (totalFeeShares * daoFeeNumerator + daoFeeDenominator - 1) / daoFeeDenominator;

        // ensure DAO's portion of fees is at least MIN_DAO_MINTING_FEE
        uint256 minDaoShares = (shares * MIN_DAO_MINTING_FEE + D18 - 1) / D18;
        if (daoFeeShares < minDaoShares) {
            daoFeeShares = minDaoShares;
        }

        // 100% to DAO, if necessary
        if (totalFeeShares < daoFeeShares) {
            totalFeeShares = daoFeeShares;
        }

        // === Transfer assets in ===

        (_assets, _amounts) = _toAssets(shares, Math.Rounding.Ceil);

        uint256 assetLength = _assets.length;
        for (uint256 i; i < assetLength; i++) {
            if (_amounts[i] != 0) {
                SafeERC20.safeTransferFrom(IERC20(_assets[i]), msg.sender, address(this), _amounts[i]);
            }
        }

        // === Mint shares ===

        _mint(receiver, shares - totalFeeShares);

        // defer fee handouts until distributeFees()
        daoPendingFeeShares += daoFeeShares;
        feeRecipientsPendingFeeShares += totalFeeShares - daoFeeShares;
    }

    /// @param shares {share} Amount of shares to redeem
    /// @param assets Assets to receive, must match basket exactly
    /// @param minAmountsOut {tok} Minimum amounts of each asset to receive
    /// @return _amounts {tok} Actual amounts transferred of each asset
    function redeem(
        uint256 shares,
        address receiver,
        address[] calldata assets,
        uint256[] calldata minAmountsOut
    ) external nonReentrant returns (uint256[] memory _amounts) {
        _poke();

        address[] memory _assets;
        (_assets, _amounts) = _toAssets(shares, Math.Rounding.Floor);

        _burn(msg.sender, shares);

        uint256 len = _assets.length;
        if (len != assets.length || len != minAmountsOut.length) {
            revert Folio__InvalidArrayLengths();
        }

        for (uint256 i; i < len; i++) {
            if (_assets[i] != assets[i]) {
                revert Folio__InvalidAsset();
            }

            if (_amounts[i] < minAmountsOut[i]) {
                revert Folio__InvalidAssetAmount(_assets[i]);
            }

            if (_amounts[i] != 0) {
                SafeERC20.safeTransfer(IERC20(_assets[i]), receiver, _amounts[i]);
            }
        }
    }

    // === Fee Shares ===

    /// @return {share} Up-to-date sum of DAO and fee recipients pending fee shares
    function getPendingFeeShares() public view returns (uint256) {
        (uint256 _daoPendingFeeShares, uint256 _feeRecipientsPendingFeeShares) = _getPendingFeeShares();
        return _daoPendingFeeShares + _feeRecipientsPendingFeeShares;
    }

    function distributeFees() public nonReentrant {
        _poke();
        // daoPendingFeeShares and feeRecipientsPendingFeeShares are up-to-date

        // Fee recipients
        uint256 _feeRecipientsPendingFeeShares = feeRecipientsPendingFeeShares;
        feeRecipientsPendingFeeShares = 0;
        uint256 feeRecipientsTotal;

        uint256 len = feeRecipients.length;
        for (uint256 i; i < len; i++) {
            // {share} = {share} * D18{1} / D18
            uint256 shares = (_feeRecipientsPendingFeeShares * feeRecipients[i].portion) / D18;
            feeRecipientsTotal += shares;

            _mint(feeRecipients[i].recipient, shares);

            emit FolioFeePaid(feeRecipients[i].recipient, shares);
        }

        // DAO
        uint256 daoShares = daoPendingFeeShares + _feeRecipientsPendingFeeShares - feeRecipientsTotal;

        (address daoRecipient, , ) = daoFeeRegistry.getFeeDetails(address(this));
        _mint(daoRecipient, daoShares);
        emit ProtocolFeePaid(daoRecipient, daoShares);

        daoPendingFeeShares = 0;
    }

    // ==== Trading ====

    function nextTradeId() external view returns (uint256) {
        return trades.length;
    }

    /// The amount on sale in an auction, dynamically increasing over time
    /// @return sellAmount {sellTok} The amount of sell token on sale in the auction at a given timestamp
    function lot(uint256 tradeId, uint256 timestamp) external view returns (uint256 sellAmount) {
        Trade storage trade = trades[tradeId];

        uint256 _totalSupply = totalSupply();
        uint256 sellBal = trade.sell.balanceOf(address(this));
        uint256 buyBal = trade.buy.balanceOf(address(this));

        // {sellTok} = D27{sellTok/share} * {share} / D27
        uint256 minSellBal = Math.mulDiv(trade.sellLimit.spot, _totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = sellBal > minSellBal ? sellBal - minSellBal : 0;

        // {buyTok} = D27{buyTok/share} * {share} / D27
        uint256 maxBuyBal = Math.mulDiv(trade.buyLimit.spot, _totalSupply, D27, Math.Rounding.Floor);
        uint256 buyAvailable = buyBal < maxBuyBal ? maxBuyBal - buyBal : 0;

        // avoid overflow
        if (buyAvailable > MAX_RATE) {
            return sellAvailable;
        }

        // D27{buyTok/sellTok}
        uint256 price = _price(trade, timestamp);

        // {sellTok} = {buyTok} * D27 / D27{buyTok/sellTok}
        uint256 sellAvailableFromBuy = Math.mulDiv(buyAvailable, D27, price, Math.Rounding.Floor);
        sellAmount = Math.min(sellAvailable, sellAvailableFromBuy);
    }

    /// @return D27{buyTok/sellTok} The price at the given timestamp as an 18-decimal fixed point
    function getPrice(uint256 tradeId, uint256 timestamp) external view returns (uint256) {
        return _price(trades[tradeId], timestamp);
    }

    /// @param sellAmount {sellTok} The amount of sell tokens the bidder is offering the protocol
    /// @return bidAmount {buyTok} The amount of buy tokens required to bid in the auction at a given timestamp
    function getBid(uint256 tradeId, uint256 timestamp, uint256 sellAmount) external view returns (uint256 bidAmount) {
        uint256 price = _price(trades[tradeId], timestamp);

        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        bidAmount = Math.mulDiv(sellAmount, price, D27, Math.Rounding.Ceil);
    }

    /// @param tradeId Use to ensure expected ordering
    /// @param sell The token to sell, from the perspective of the Folio
    /// @param buy The token to buy, from the perspective of the Folio
    /// @param sellLimit D27{sellTok/share} min ratio of sell token to shares allowed, inclusive, 1e54 max
    /// @param buyLimit D27{buyTok/share} max balance-ratio to shares allowed, exclusive, 1e54 max
    /// @param prices D27{buyTok/sellTok} Price range
    /// @param ttl {s} How long a trade can exist in an APPROVED state until it can no longer be OPENED
    ///     (once opened, it always finishes).
    ///     Must be longer than tradeDelay if intended to be permissionlessly available.
    function approveTrade(
        uint256 tradeId,
        IERC20 sell,
        IERC20 buy,
        Range calldata sellLimit,
        Range calldata buyLimit,
        Prices calldata prices,
        uint256 ttl
    ) external nonReentrant onlyRole(TRADE_PROPOSER) {
        require(!isKilled, Folio__FolioKilled());

        if (trades.length != tradeId) {
            revert Folio__InvalidTradeId();
        }

        if (address(sell) == address(0) || address(buy) == address(0) || address(sell) == address(buy)) {
            revert Folio__InvalidTradeTokens();
        }

        if (
            sellLimit.spot > MAX_RATE ||
            sellLimit.high > MAX_RATE ||
            sellLimit.low > sellLimit.spot ||
            sellLimit.high < sellLimit.spot
        ) {
            revert Folio__InvalidSellLimit();
        }

        if (
            buyLimit.spot == 0 ||
            buyLimit.spot > MAX_RATE ||
            buyLimit.high > MAX_RATE ||
            buyLimit.low > buyLimit.spot ||
            buyLimit.high < buyLimit.spot
        ) {
            revert Folio__InvalidBuyLimit();
        }

        if (prices.start < prices.end) {
            revert Folio__InvalidPrices();
        }

        if (ttl > MAX_TTL) {
            revert Folio__InvalidTradeTTL();
        }

        Trade memory trade = Trade({
            id: trades.length,
            sell: sell,
            buy: buy,
            sellLimit: sellLimit,
            buyLimit: buyLimit,
            prices: prices,
            availableAt: block.timestamp + tradeDelay,
            launchTimeout: block.timestamp + ttl,
            start: 0,
            end: 0,
            k: 0
        });

        trades.push(trade);

        emit TradeApproved(tradeId, address(sell), address(buy), trade);
    }

    /// Open a trade as the trade launcher
    /// @param sellLimit D27{sellTok/share} min ratio of sell token to shares allowed, inclusive, 1e54 max
    /// @param buyLimit D27{buyTok/share} max balance-ratio to shares allowed, exclusive, 1e54 max
    /// @param startPrice D27{buyTok/sellTok} 1e54 max
    /// @param endPrice D27{buyTok/sellTok} 1e54 max
    function openTrade(
        uint256 tradeId,
        uint256 sellLimit,
        uint256 buyLimit,
        uint256 startPrice,
        uint256 endPrice
    ) external nonReentrant onlyRole(TRADE_LAUNCHER) {
        Trade storage trade = trades[tradeId];

        // trade launcher can:
        //   - select a sell limit within the approved range
        //   - select a buy limit within the approved range
        //   - raise starting price by up to 100x
        //   - raise ending price arbitrarily (can cause auction not to clear, same as killing)

        if (
            startPrice < trade.prices.start ||
            endPrice < trade.prices.end ||
            (trade.prices.start != 0 && startPrice > 100 * trade.prices.start)
        ) {
            revert Folio__InvalidPrices();
        }

        if (sellLimit < trade.sellLimit.low || sellLimit > trade.sellLimit.high) {
            revert Folio__InvalidSellLimit();
        }

        if (buyLimit < trade.buyLimit.low || buyLimit > trade.buyLimit.high) {
            revert Folio__InvalidBuyLimit();
        }

        trade.sellLimit.spot = sellLimit;
        trade.buyLimit.spot = buyLimit;
        trade.prices.start = startPrice;
        trade.prices.end = endPrice;
        // more price checks in _openTrade()

        _openTrade(trade);
    }

    /// @dev Permissionless, callable only after the trading delay
    function openTradePermissionlessly(uint256 tradeId) external nonReentrant {
        Trade storage trade = trades[tradeId];

        // only open trades that have not timed out (ttl check)
        if (block.timestamp < trade.availableAt) {
            revert Folio__TradeCannotBeOpenedPermissionlesslyYet();
        }

        _openTrade(trade);
    }

    /// Bid in an ongoing auction
    ///   If withCallback is true, caller must adhere to IBidderCallee interface and receives a callback
    ///   If withCallback is false, caller must have provided an allowance in advance
    /// @dev Permissionless
    /// @param sellAmount {sellTok} Sell token, the token the bidder receives
    /// @param maxBuyAmount {buyTok} Max buy token, the token the bidder provides
    /// @param withCallback If true, caller must adhere to IBidderCallee interface and transfers tokens via callback
    /// @param data Arbitrary data to pass to the callback
    /// @return boughtAmt {buyTok} The amount bidder receives
    function bid(
        uint256 tradeId,
        uint256 sellAmount,
        uint256 maxBuyAmount,
        bool withCallback,
        bytes calldata data
    ) external nonReentrant returns (uint256 boughtAmt) {
        Trade storage trade = trades[tradeId];

        // checks trade is ongoing
        // D27{buyTok/sellTok}
        uint256 price = _price(trade, block.timestamp);

        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        boughtAmt = Math.mulDiv(sellAmount, price, D27, Math.Rounding.Ceil);
        if (boughtAmt > maxBuyAmount) {
            revert Folio__SlippageExceeded();
        }

        // TODO think about fee shares inflating supply over time
        uint256 _totalSupply = totalSupply();
        uint256 sellBal = trade.sell.balanceOf(address(this));

        // {sellTok} = D27{sellTok/share} * {share} / D27
        uint256 minSellBal = Math.mulDiv(trade.sellLimit.spot, _totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = sellBal > minSellBal ? sellBal - minSellBal : 0;

        // ensure auction is large enough to cover bid
        if (sellAmount > sellAvailable) {
            revert Folio__InsufficientBalance();
        }

        // put buy token in basket
        basket.add(address(trade.buy));

        // pay bidder
        trade.sell.safeTransfer(msg.sender, sellAmount);

        emit TradeBid(tradeId, sellAmount, boughtAmt);

        // QoL feature: close auction and eject token from basket if we have sold all of it
        if (trade.sell.balanceOf(address(this)) == 0) {
            basket.remove(address(trade.sell));
            trade.end = block.timestamp;
            sellEnds[address(trade.sell)] = block.timestamp;
            buyEnds[address(trade.buy)] = block.timestamp;
        }

        // collect payment from bidder
        if (withCallback) {
            uint256 balBefore = trade.buy.balanceOf(address(this));

            IBidderCallee(msg.sender).bidCallback(address(trade.buy), boughtAmt, data);

            if (trade.buy.balanceOf(address(this)) - balBefore < boughtAmt) {
                revert Folio__InsufficientBid();
            }
        } else {
            trade.buy.safeTransferFrom(msg.sender, address(this), boughtAmt);
        }

        // D27{buyTok/share} = D27{buyTok/share} * {share} / D27
        uint256 maxBuyBal = Math.mulDiv(trade.buyLimit.spot, _totalSupply, D27, Math.Rounding.Floor);

        // ensure post-bid buy balance does not exceed max
        if (trade.buy.balanceOf(address(this)) > maxBuyBal) {
            revert Folio__ExcessiveBid();
        }
    }

    /// Kill a trade
    /// A trade can be killed anywhere in its lifecycle, and cannot be restarted
    /// @dev Callable by TRADE_PROPOSER or TRADE_LAUNCHER
    function killTrade(uint256 tradeId) external nonReentrant {
        if (!hasRole(TRADE_PROPOSER, msg.sender) && !hasRole(TRADE_LAUNCHER, msg.sender)) {
            revert Folio__Unauthorized();
        }

        // do not revert, to prevent griefing

        Trade storage trade = trades[tradeId];
        trade.end = 1;
        sellEnds[address(trade.sell)] = block.timestamp;
        buyEnds[address(trade.buy)] = block.timestamp;
        emit TradeKilled(tradeId);
    }

    // ==== Internal ====

    // {share} -> ({tokAddress}, {tok})
    function _toAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view returns (address[] memory _assets, uint256[] memory _amounts) {
        uint256 _totalSupply = totalSupply();

        _assets = basket.values();

        uint256 len = _assets.length;
        _amounts = new uint256[](len);
        for (uint256 i; i < len; i++) {
            uint256 assetBal = IERC20(_assets[i]).balanceOf(address(this));

            // {tok} = {share} * {tok} / {share}
            _amounts[i] = Math.mulDiv(shares, assetBal, _totalSupply, rounding);
        }
    }

    function _openTrade(Trade storage trade) internal {
        require(!isKilled, Folio__FolioKilled());

        // only open APPROVED trades
        if (trade.start != 0 || trade.end != 0) {
            revert Folio__TradeCannotBeOpened();
        }

        // do not open trades that have timed out from ttl
        if (block.timestamp > trade.launchTimeout) {
            revert Folio__TradeTimeout();
        }

        // ensure no conflicting tokens across trades (same sell or sell buy is okay)
        // necessary to prevent dutch auctions from taking losses
        if (block.timestamp <= sellEnds[address(trade.buy)] || block.timestamp <= buyEnds[address(trade.sell)]) {
            revert Folio__TradeCollision();
        }
        sellEnds[address(trade.sell)] = Math.max(sellEnds[address(trade.sell)], block.timestamp + auctionLength);
        buyEnds[address(trade.buy)] = Math.max(buyEnds[address(trade.buy)], block.timestamp + auctionLength);

        // ensure valid price range (startPrice == endPrice is valid)
        if (
            trade.prices.start < trade.prices.end ||
            trade.prices.start == 0 ||
            trade.prices.end == 0 ||
            trade.prices.start > MAX_RATE ||
            trade.prices.start / trade.prices.end > MAX_PRICE_RANGE
        ) {
            revert Folio__InvalidPrices();
        }

        trade.start = block.timestamp;
        trade.end = block.timestamp + auctionLength;

        emit TradeOpened(trade.id, trade);

        // D18{1}
        // k = ln(P_0 / P_t) / t
        trade.k = UD60x18.wrap((trade.prices.start * D18) / trade.prices.end).ln().unwrap() / auctionLength;
        // gas optimization to avoid recomputing k on every bid
    }

    /// @return p D27{buyTok/sellTok}
    function _price(Trade storage trade, uint256 timestamp) internal view returns (uint256 p) {
        // ensure auction is ongoing
        if (timestamp < trade.start || timestamp > trade.end) {
            revert Folio__TradeNotOngoing();
        }
        if (timestamp == trade.start) {
            return trade.prices.start;
        }
        if (timestamp == trade.end) {
            return trade.prices.end;
        }

        uint256 elapsed = timestamp - trade.start;

        // P_t = P_0 * e ^ -kt
        // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
        p = (trade.prices.start * intoUint256(exp(SD59x18.wrap(-1 * int256(trade.k * elapsed))))) / D18;
        if (p < trade.prices.end) {
            p = trade.prices.end;
        }
    }

    /// @return _daoPendingFeeShares {share}
    /// @return _feeRecipientsPendingFeeShares {share}
    function _getPendingFeeShares()
        internal
        view
        returns (uint256 _daoPendingFeeShares, uint256 _feeRecipientsPendingFeeShares)
    {
        _daoPendingFeeShares = daoPendingFeeShares;
        _feeRecipientsPendingFeeShares = feeRecipientsPendingFeeShares;

        uint256 supply = super.totalSupply() + _daoPendingFeeShares + _feeRecipientsPendingFeeShares;
        uint256 elapsed = block.timestamp - lastPoke;

        // {share} += {share} * D18 / D18{1/s} ^ {s} - {share}
        uint256 feeShares = (supply * D18) / UD60x18.wrap(D18 - folioFee).powu(elapsed).unwrap() - supply;

        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(this));

        uint256 daoShares = (feeShares * daoFeeNumerator + daoFeeDenominator - 1) / daoFeeDenominator;
        _daoPendingFeeShares += daoShares;
        _feeRecipientsPendingFeeShares += feeShares - daoShares;
    }

    /// @dev Set folio fee by annual percentage
    /// @param _newFeeAnnually {s}
    function _setFolioFee(uint256 _newFeeAnnually) internal {
        if (_newFeeAnnually > MAX_FOLIO_FEE) {
            revert Folio__FolioFeeTooHigh();
        }

        // convert annual percentage to per-second
        // = 1 - (1 - _newFeeAnnually) ^ (1 / 31536000)
        folioFee = D18 - UD60x18.wrap(D18 - _newFeeAnnually).pow(ANNUALIZATION_EXP).unwrap();

        if (_newFeeAnnually != 0 && folioFee == 0) {
            revert Folio__FolioFeeTooLow();
        }

        emit FolioFeeSet(folioFee, _newFeeAnnually);
    }

    function _setMintingFee(uint256 _newFee) internal {
        if (_newFee > MAX_MINTING_FEE) {
            revert Folio__MintingFeeTooHigh();
        }

        mintingFee = _newFee;
        emit MintingFeeSet(_newFee);
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
        if (len > MAX_FEE_RECIPIENTS) {
            revert Folio__TooManyFeeRecipients();
        }

        address previousRecipient;

        for (uint256 i; i < len; i++) {
            if (_feeRecipients[i].recipient <= previousRecipient) {
                revert Folio__FeeRecipientInvalidAddress();
            }

            if (_feeRecipients[i].portion == 0) {
                revert Folio__FeeRecipientInvalidFeeShare();
            }

            total += _feeRecipients[i].portion;
            previousRecipient = _feeRecipients[i].recipient;
            feeRecipients.push(_feeRecipients[i]);
            emit FeeRecipientSet(_feeRecipients[i].recipient, _feeRecipients[i].portion);
        }

        // ensure table adds up to 100%
        if (total != D18) {
            revert Folio__BadFeeTotal();
        }
    }

    function _setTradeDelay(uint256 _newDelay) internal {
        if (_newDelay > MAX_TRADE_DELAY) {
            revert Folio__InvalidTradeDelay();
        }
        tradeDelay = _newDelay;
        emit TradeDelaySet(_newDelay);
    }

    function _setAuctionLength(uint256 _newLength) internal {
        if (_newLength < MIN_AUCTION_LENGTH || _newLength > MAX_AUCTION_LENGTH) {
            revert Folio__InvalidAuctionLength();
        }

        auctionLength = _newLength;
        emit AuctionLengthSet(auctionLength);
    }

    /// @dev After: daoPendingFeeShares and feeRecipientsPendingFeeShares are up-to-date
    function _poke() internal {
        if (lastPoke == block.timestamp) {
            return;
        }

        (daoPendingFeeShares, feeRecipientsPendingFeeShares) = _getPendingFeeShares();
        lastPoke = block.timestamp;
    }
}
