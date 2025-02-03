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

/// Optional bidder interface for callback
interface IBidderCallee {
    /// @param buyAmount {qBuyTok}
    function bidCallback(address buyToken, uint256 buyAmount, bytes calldata data) external;
}

uint256 constant MAX_TVL_FEE = 0.1e18; // D18{1/year} 10% annually
uint256 constant MAX_MINT_FEE = 0.05e18; // D18{1} 5%
uint256 constant MIN_AUCTION_LENGTH = 60; // {s} 1 min
uint256 constant MAX_AUCTION_LENGTH = 604800; // {s} 1 week
uint256 constant MAX_AUCTION_DELAY = 604800; // {s} 1 week
uint256 constant MAX_FEE_RECIPIENTS = 64;
uint256 constant MAX_TTL = 604800 * 4; // {s} 4 weeks
uint256 constant MAX_RATE = 1e54; // D18{buyTok/sellTok}
uint256 constant MAX_PRICE_RANGE = 1e9; // {1}

UD60x18 constant ANNUALIZER = UD60x18.wrap(31709791983); // D18{1/s} 1e18 / 31536000

uint256 constant D18 = 1e18; // D18
uint256 constant D27 = 1e27; // D27

/**
 * @title Folio
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Folio is a backed ERC20 token with permissionless minting/redemption and rebalancing via dutch auction
 *
 * There are 3 main roles:
 *   1. DEFAULT_ADMIN_ROLE: can add/remove erc20 assets, set fees, auction length, auction delay, and close auctions
 *   2. AUCTION_APPROVER: can approve auctions
 *   3. AUCTION_LAUNCHER: can open auctions, optionally providing some amount of additional detail
 *
 * Permissionless execution is available after a delay if the AUCTION_LAUNCHER is not online or the Folio is configured
 * without an AUCTION_LAUNCHER.
 *
 * Auction lifecycle:
 *   approveAuction() -> openAuction() -> bid() -> [optional] closeAuction()
 *
 * Auctions will attempt to close themselves once the sell token's balance reaches the sellLimit. However, they can
 * also be closed by *any* of the 3 roles, if it is discovered one of the exchange rates has been set incorrectly.
 *
 * A Folio is backed by aa flexible number of ERC20 tokens of any denomination/price (within assumed ranges, see README)
 * All tokens tracked by the Folio are required to issue/redeem. This forms the basket.
 *
 * Rebalancing targets are defined in terms of basket ratios: ratio of token to the Folio share, units D27{tok/share}.
 *
 * Fees:
 *   - TVL fee: fee per unit time
 *   - Mint fee: fee on mint
 *
 * After both fees have been applied, the DAO takes a cut based on the configuration of the FolioDAOFeeRegistry.
 * The remaining portion is distributed to the Folio's fee recipients.
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
    bytes32 public constant AUCTION_APPROVER = keccak256("AUCTION_APPROVER"); // expected to be trading governance's timelock
    bytes32 public constant AUCTION_LAUNCHER = keccak256("AUCTION_LAUNCHER"); // optional: EOA or multisig
    bytes32 public constant BRAND_MANAGER = keccak256("BRAND_MANAGER"); // optional: no permissions

    /**
     * Mandate
     */
    string public mandate; // mutable field that describes mission/brand of the Folio

    /**
     * Basket
     */
    EnumerableSet.AddressSet private basket;

    /**
     * Fees
     */
    FeeRecipient[] public feeRecipients;
    uint256 public tvlFee; // D18{1/s} demurrage fee on AUM
    uint256 public mintFee; // D18{1} fee on mint

    /**
     * System
     */
    uint256 public lastPoke; // {s}
    uint256 public daoPendingFeeShares; // {share} shares pending to be distributed ONLY to the DAO
    uint256 public feeRecipientsPendingFeeShares; // {share} shares pending to be distributed ONLY to fee recipients
    bool public isKilled; // {bool} If true, Folio goes into redemption-only mode

    /**
     * Rebalancing
     *   APPROVED -> OPEN -> CLOSED
     *   - Approved auctions have a delay before they can be opened, that AUCTION_LAUNCHER can bypass
     *   - Multiple auctions can be open at once, though a token cannot be bought and sold simultaneously
     *   - Multiple bids can be executed against the same auction
     *   - All auctions are dutch auctions with the same price curve, but it's possible to pass startPrice = endPrice
     */
    Auction[] public auctions;
    mapping(address => uint256) public sellEnds; // {s} timestamp of latest ongoing auction for sells
    mapping(address => uint256) public buyEnds; // {s} timestamp of latest ongoing auction for buys
    uint256 public auctionDelay; // {s} delay in the APPROVED state before an auction can be permissionlessly opened
    uint256 public auctionLength; // {s} length of an auction

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
        _setTVLFee(_additionalDetails.tvlFee);
        _setMintFee(_additionalDetails.mintFee);
        _setAuctionDelay(_additionalDetails.auctionDelay);
        _setAuctionLength(_additionalDetails.auctionLength);
        _setMandate(_additionalDetails.mandate);

        daoFeeRegistry = IFolioDAOFeeRegistry(_daoFeeRegistry);

        require(_basicDetails.initialShares != 0, Folio__ZeroInitialShares());

        uint256 assetLength = _basicDetails.assets.length;
        require(assetLength != 0, Folio__EmptyAssets());

        for (uint256 i; i < assetLength; i++) {
            require(_basicDetails.assets[i] != address(0), Folio__InvalidAsset());

            uint256 assetBalance = IERC20(_basicDetails.assets[i]).balanceOf(address(this));
            require(assetBalance != 0, Folio__InvalidAssetAmount(_basicDetails.assets[i]));

            _addToBasket(_basicDetails.assets[i]);
        }

        lastPoke = block.timestamp;
        _mint(_creator, _basicDetails.initialShares);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @dev Testing function, no production use
    function poke() external nonReentrant {
        _poke();
    }

    // ==== Governance ====

    /// Escape hatch function to be used when tokens get acquired not through an auction but
    /// through any other means and should become part of the Folio.
    /// @dev Does not require a token balance
    /// @param token The token to add to the basket
    function addToBasket(IERC20 token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_addToBasket(address(token)), Folio__BasketModificationFailed());
    }

    /// @dev Enables removal of tokens with nonzero balance
    function removeFromBasket(IERC20 token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_removeFromBasket(address(token)), Folio__BasketModificationFailed());
    }

    /// An annual tvl fee below the DAO fee floor will result in the entirety of the fee being sent to the DAO
    /// @dev Non-reentrant via distributeFees()
    /// @param _newFee D18{1/s} Fee per second on AUM
    function setTVLFee(uint256 _newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setTVLFee(_newFee);
    }

    /// A minting fee below the DAO fee floor will result in the entirety of the fee being sent to the DAO
    /// @dev Non-reentrant via distributeFees()
    /// @param _newFee D18{1} Fee on mint
    function setMintFee(uint256 _newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setMintFee(_newFee);
    }

    /// @dev Non-reentrant via distributeFees()
    /// @dev Fee recipients must be unique and sorted by address, and sum to 1e18
    function setFeeRecipients(FeeRecipient[] memory _newRecipients) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setFeeRecipients(_newRecipients);
    }

    /// @param _newDelay {s} Delay after a auction has been approved before it can be permissionlessly opened
    function setAuctionDelay(uint256 _newDelay) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAuctionDelay(_newDelay);
    }

    /// @param _newLength {s} Length of an auction
    function setAuctionLength(uint256 _newLength) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAuctionLength(_newLength);
    }

    function setMandate(string calldata _newMandate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMandate(_newMandate);
    }

    /// Kill the Folio, callable only by the admin
    /// @dev Folio cannot be issued and auctions cannot be approved, opened, or bid on
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

    /// @return _assets
    /// @return _amounts {tok}
    function folio() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        return toAssets(10 ** decimals(), Math.Rounding.Floor);
    }

    /// @return _assets
    /// @return _amounts {tok}
    function totalAssets() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        _assets = basket.values();

        uint256 assetLength = _assets.length;
        _amounts = new uint256[](assetLength);
        for (uint256 i; i < assetLength; i++) {
            _amounts[i] = IERC20(_assets[i]).balanceOf(address(this));
        }
    }

    /// @param shares {share}
    /// @return _assets
    /// @return _amounts {tok}
    function toAssets(
        uint256 shares,
        Math.Rounding rounding
    ) public view returns (address[] memory _assets, uint256[] memory _amounts) {
        require(!_reentrancyGuardEntered(), ReentrancyGuardReentrantCall());

        return _toAssets(shares, rounding);
    }

    /// @param shares {share} Amount of shares to redeem
    /// @return _assets
    /// @return _amounts {tok}
    /// @dev Use allowances to set slippage limits
    /// @dev Minting has 3 share-portions: (i) receiver shares, (ii) DAO fee shares, (iii) fee recipients shares
    function mint(
        uint256 shares,
        address receiver
    ) external nonReentrant returns (address[] memory _assets, uint256[] memory _amounts) {
        require(!isKilled, Folio__FolioKilled());

        _poke();

        // === Calculate fee shares ===

        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator, uint256 daoFeeFloor) = daoFeeRegistry.getFeeDetails(
            address(this)
        );

        // {share} = {share} * D18{1} / D18
        uint256 totalFeeShares = (shares * mintFee + D18 - 1) / D18;
        uint256 daoFeeShares = (totalFeeShares * daoFeeNumerator + daoFeeDenominator - 1) / daoFeeDenominator;

        // ensure DAO's portion of fees is at least the DAO feeFloor
        uint256 minDaoShares = (shares * daoFeeFloor + D18 - 1) / D18;
        daoFeeShares = daoFeeShares < minDaoShares ? minDaoShares : daoFeeShares;

        // 100% to DAO, if necessary
        totalFeeShares = totalFeeShares < daoFeeShares ? daoFeeShares : totalFeeShares;

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

        // === Burn shares ===

        _burn(msg.sender, shares);

        // === Transfer assets out ===

        uint256 len = _assets.length;
        require(len == assets.length && len == minAmountsOut.length, Folio__InvalidArrayLengths());

        for (uint256 i; i < len; i++) {
            require(_assets[i] == assets[i], Folio__InvalidAsset());
            require(_amounts[i] >= minAmountsOut[i], Folio__InvalidAssetAmount(_assets[i]));

            if (_amounts[i] != 0) {
                SafeERC20.safeTransfer(IERC20(_assets[i]), receiver, _amounts[i]);
            }
        }
    }

    // ==== Fee Shares ====

    /// @return {share} Up-to-date sum of DAO and fee recipients pending fee shares
    function getPendingFeeShares() public view returns (uint256) {
        (uint256 _daoPendingFeeShares, uint256 _feeRecipientsPendingFeeShares) = _getPendingFeeShares();
        return _daoPendingFeeShares + _feeRecipientsPendingFeeShares;
    }

    /// Distribute all pending fee shares
    /// @dev Recipients: DAO and fee recipients
    /// @dev Pending fee shares are already reflected in the total supply, this function only concretizes balances
    function distributeFees() public nonReentrant {
        _poke();
        // daoPendingFeeShares and feeRecipientsPendingFeeShares are up-to-date

        // === Fee recipients ===

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

        // === DAO ===

        // {share}
        uint256 daoShares = daoPendingFeeShares + _feeRecipientsPendingFeeShares - feeRecipientsTotal;

        (address daoRecipient, , , ) = daoFeeRegistry.getFeeDetails(address(this));
        _mint(daoRecipient, daoShares);
        emit ProtocolFeePaid(daoRecipient, daoShares);

        daoPendingFeeShares = 0;
    }

    // ==== Rebalancing ====

    function nextAuctionId() external view returns (uint256) {
        return auctions.length;
    }

    /// The amount on sale in an auction
    /// @dev Can be bid on in chunks
    /// @dev Fluctuates changes over time as price changes (can go up or down)
    /// @return sellAmount {sellTok} The amount of sell token on sale in the auction at a given timestamp
    function lot(uint256 auctionId, uint256 timestamp) external view returns (uint256 sellAmount) {
        Auction storage auction = auctions[auctionId];

        uint256 _totalSupply = totalSupply();
        uint256 sellBal = auction.sell.balanceOf(address(this));
        uint256 buyBal = auction.buy.balanceOf(address(this));

        // {sellTok} = D27{sellTok/share} * {share} / D27
        uint256 minSellBal = Math.mulDiv(auction.sellLimit.spot, _totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = sellBal > minSellBal ? sellBal - minSellBal : 0;

        // {buyTok} = D27{buyTok/share} * {share} / D27
        uint256 maxBuyBal = Math.mulDiv(auction.buyLimit.spot, _totalSupply, D27, Math.Rounding.Floor);
        uint256 buyAvailable = buyBal < maxBuyBal ? maxBuyBal - buyBal : 0;

        // avoid overflow
        if (buyAvailable > MAX_RATE) {
            return sellAvailable;
        }

        // D27{buyTok/sellTok}
        uint256 price = _price(auction, timestamp);

        // {sellTok} = {buyTok} * D27 / D27{buyTok/sellTok}
        uint256 sellAvailableFromBuy = Math.mulDiv(buyAvailable, D27, price, Math.Rounding.Floor);
        sellAmount = Math.min(sellAvailable, sellAvailableFromBuy);
    }

    /// @return D27{buyTok/sellTok} The price at the given timestamp as an 27-decimal fixed point
    function getPrice(uint256 auctionId, uint256 timestamp) external view returns (uint256) {
        return _price(auctions[auctionId], timestamp);
    }

    /// Get the bid amount required to purchase the sell amount
    /// @param sellAmount {sellTok} The amount of sell tokens the bidder is offering the protocol
    /// @return bidAmount {buyTok} The amount of buy tokens required to bid in the auction at a given timestamp
    function getBid(
        uint256 auctionId,
        uint256 timestamp,
        uint256 sellAmount
    ) external view returns (uint256 bidAmount) {
        uint256 price = _price(auctions[auctionId], timestamp);

        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        bidAmount = Math.mulDiv(sellAmount, price, D27, Math.Rounding.Ceil);
    }

    /// Approve an auction to run
    /// @param sell The token to sell, from the perspective of the Folio
    /// @param buy The token to buy, from the perspective of the Folio
    /// @param sellLimit D27{sellTok/share} min ratio of sell token to shares allowed, inclusive, 1e54 max
    /// @param buyLimit D27{buyTok/share} max balance-ratio to shares allowed, exclusive, 1e54 max
    /// @param prices D27{buyTok/sellTok} Price range
    /// @param ttl {s} How long a auction can exist in an APPROVED state until it can no longer be OPENED
    ///     (once opened, it always finishes).
    ///     Must be longer than auctionDelay if intended to be permissionlessly available.
    function approveAuction(
        IERC20 sell,
        IERC20 buy,
        BasketRange calldata sellLimit,
        BasketRange calldata buyLimit,
        Prices calldata prices,
        uint256 ttl
    ) external nonReentrant onlyRole(AUCTION_APPROVER) {
        require(!isKilled, Folio__FolioKilled());

        require(
            address(sell) != address(0) && address(buy) != address(0) && address(sell) != address(buy),
            Folio__InvalidAuctionTokens()
        );

        require(
            sellLimit.high <= MAX_RATE && sellLimit.low <= sellLimit.spot && sellLimit.high >= sellLimit.spot,
            Folio__InvalidSellLimit()
        );

        require(
            buyLimit.low != 0 &&
                buyLimit.high <= MAX_RATE &&
                buyLimit.low <= buyLimit.spot &&
                buyLimit.high >= buyLimit.spot,
            Folio__InvalidBuyLimit()
        );

        require(prices.start >= prices.end, Folio__InvalidPrices());

        require(ttl <= MAX_TTL, Folio__InvalidAuctionTTL());

        Auction memory auction = Auction({
            id: auctions.length,
            sell: sell,
            buy: buy,
            sellLimit: sellLimit,
            buyLimit: buyLimit,
            prices: prices,
            availableAt: block.timestamp + auctionDelay,
            launchTimeout: block.timestamp + ttl,
            start: 0,
            end: 0,
            k: 0
        });

        auctions.push(auction);

        emit AuctionApproved(auction.id, address(sell), address(buy), auction);
    }

    /// Open an auction as the auction launcher
    /// @param sellLimit D27{sellTok/share} min ratio of sell token to shares allowed, inclusive, 1e54 max
    /// @param buyLimit D27{buyTok/share} max balance-ratio to shares allowed, exclusive, 1e54 max
    /// @param startPrice D27{buyTok/sellTok} 1e54 max
    /// @param endPrice D27{buyTok/sellTok} 1e54 max
    function openAuction(
        uint256 auctionId,
        uint256 sellLimit,
        uint256 buyLimit,
        uint256 startPrice,
        uint256 endPrice
    ) external nonReentrant onlyRole(AUCTION_LAUNCHER) {
        Auction storage auction = auctions[auctionId];

        // auction launcher can:
        //   - select a sell limit within the approved range
        //   - select a buy limit within the approved range
        //   - raise starting price by up to 100x
        //   - raise ending price arbitrarily (can cause auction not to clear, same as closing auction)

        require(
            startPrice >= auction.prices.start &&
                endPrice >= auction.prices.end &&
                (auction.prices.start == 0 || startPrice <= 100 * auction.prices.start),
            Folio__InvalidPrices()
        );

        require(sellLimit >= auction.sellLimit.low && sellLimit <= auction.sellLimit.high, Folio__InvalidSellLimit());

        require(buyLimit >= auction.buyLimit.low && buyLimit <= auction.buyLimit.high, Folio__InvalidBuyLimit());

        auction.sellLimit.spot = sellLimit;
        auction.buyLimit.spot = buyLimit;
        auction.prices.start = startPrice;
        auction.prices.end = endPrice;
        // more price checks in _openAuction()

        _openAuction(auction);
    }

    /// Open an auction permissionlessly
    /// @dev Permissionless, callable only after the auction delay
    function openAuctionPermissionlessly(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];

        // only open auctions that have not timed out (ttl check)
        require(block.timestamp >= auction.availableAt, Folio__AuctionCannotBeOpenedPermissionlesslyYet());

        _openAuction(auction);
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
        uint256 auctionId,
        uint256 sellAmount,
        uint256 maxBuyAmount,
        bool withCallback,
        bytes calldata data
    ) external nonReentrant returns (uint256 boughtAmt) {
        require(!isKilled, Folio__FolioKilled());
        Auction storage auction = auctions[auctionId];

        // checks auction is ongoing
        // D27{buyTok/sellTok}
        uint256 price = _price(auction, block.timestamp);

        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        boughtAmt = Math.mulDiv(sellAmount, price, D27, Math.Rounding.Ceil);
        require(boughtAmt <= maxBuyAmount, Folio__SlippageExceeded());

        // totalSupply inflates over time due to TVL fee, causing buyLimits/sellLimits to be slightly stale
        uint256 _totalSupply = totalSupply();
        uint256 sellBal = auction.sell.balanceOf(address(this));

        // {sellTok} = D27{sellTok/share} * {share} / D27
        uint256 minSellBal = Math.mulDiv(auction.sellLimit.spot, _totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = sellBal > minSellBal ? sellBal - minSellBal : 0;

        // ensure auction is large enough to cover bid
        require(sellAmount <= sellAvailable, Folio__InsufficientBalance());

        // put buy token in basket
        _addToBasket(address(auction.buy));

        // pay bidder
        auction.sell.safeTransfer(msg.sender, sellAmount);

        emit AuctionBid(auctionId, sellAmount, boughtAmt);

        // QoL: close auction if we have reached the sell limit
        sellBal = auction.sell.balanceOf(address(this));
        if (sellBal <= minSellBal) {
            auction.end = block.timestamp;
            // cannot update sellEnds/buyEnds due to possibility of parallel auctions

            if (sellBal == 0) {
                _removeFromBasket(address(auction.sell));
            }
        }

        // collect payment from bidder
        if (withCallback) {
            uint256 balBefore = auction.buy.balanceOf(address(this));

            IBidderCallee(msg.sender).bidCallback(address(auction.buy), boughtAmt, data);

            require(auction.buy.balanceOf(address(this)) - balBefore >= boughtAmt, Folio__InsufficientBid());
        } else {
            auction.buy.safeTransferFrom(msg.sender, address(this), boughtAmt);
        }

        // D27{buyTok/share} = D27{buyTok/share} * {share} / D27
        uint256 maxBuyBal = Math.mulDiv(auction.buyLimit.spot, _totalSupply, D27, Math.Rounding.Floor);

        // ensure post-bid buy balance does not exceed max
        require(auction.buy.balanceOf(address(this)) <= maxBuyBal, Folio__ExcessiveBid());
    }

    /// Close an auction
    /// A auction can be closed from anywhere in its lifecycle, and cannot be restarted
    /// @dev Callable by AUCTION_APPROVER or AUCTION_LAUNCHER or ADMIN
    function closeAuction(uint256 auctionId) external nonReentrant {
        require(
            hasRole(AUCTION_APPROVER, msg.sender) ||
                hasRole(AUCTION_LAUNCHER, msg.sender) ||
                hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            Folio__Unauthorized()
        );

        // do not revert, to prevent griefing
        auctions[auctionId].end = 1;

        emit AuctionClosed(auctionId);
    }

    // ==== Internal ====

    /// @param shares {share}
    /// @return _assets
    /// @return _amounts {tok}
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

    function _openAuction(Auction storage auction) internal {
        require(!isKilled, Folio__FolioKilled());

        // only open APPROVED auctions
        require(auction.start == 0 && auction.end == 0, Folio__AuctionCannotBeOpened());

        // do not open auctions that have timed out from ttl
        require(block.timestamp <= auction.launchTimeout, Folio__AuctionTimeout());

        // ensure no conflicting tokens across auctions (same sell or sell buy is okay)
        // necessary to prevent dutch auctions from taking losses
        require(
            block.timestamp > sellEnds[address(auction.buy)] && block.timestamp > buyEnds[address(auction.sell)],
            Folio__AuctionCollision()
        );

        sellEnds[address(auction.sell)] = Math.max(sellEnds[address(auction.sell)], block.timestamp + auctionLength);
        buyEnds[address(auction.buy)] = Math.max(buyEnds[address(auction.buy)], block.timestamp + auctionLength);

        // ensure valid price range (startPrice == endPrice is valid)
        require(
            auction.prices.start >= auction.prices.end &&
                auction.prices.end != 0 &&
                auction.prices.start <= MAX_RATE &&
                auction.prices.start / auction.prices.end <= MAX_PRICE_RANGE,
            Folio__InvalidPrices()
        );

        auction.start = block.timestamp;
        auction.end = block.timestamp + auctionLength;

        emit AuctionOpened(auction.id, auction);

        // D18{1}
        // k = ln(P_0 / P_t) / t
        auction.k = UD60x18.wrap((auction.prices.start * D18) / auction.prices.end).ln().unwrap() / auctionLength;
        // gas optimization to avoid recomputing k on every bid
    }

    /// @return p D27{buyTok/sellTok}
    function _price(Auction storage auction, uint256 timestamp) internal view returns (uint256 p) {
        // ensure auction is ongoing
        require(timestamp >= auction.start && timestamp <= auction.end, Folio__AuctionNotOngoing());

        if (timestamp == auction.start) {
            return auction.prices.start;
        }
        if (timestamp == auction.end) {
            return auction.prices.end;
        }

        uint256 elapsed = timestamp - auction.start;

        // P_t = P_0 * e ^ -kt
        // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
        p = (auction.prices.start * intoUint256(exp(SD59x18.wrap(-1 * int256(auction.k * elapsed))))) / D18;
        if (p < auction.prices.end) {
            p = auction.prices.end;
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

        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator, uint256 daoFeeFloor) = daoFeeRegistry.getFeeDetails(
            address(this)
        );

        // convert annual percentage to per-second for comparison with stored tvlFee
        // = 1 - (1 - feeFloor) ^ (1 / 31536000)
        // D18{1/s} = D18{1} - D18{1} * D18{1} ^ D18{1/s}
        uint256 feeFloor = D18 - UD60x18.wrap(D18 - daoFeeFloor).pow(ANNUALIZER).unwrap();

        // D18{1/s}
        uint256 _tvlFee = feeFloor > tvlFee ? feeFloor : tvlFee;

        // {share} += {share} * D18 / D18{1/s} ^ {s} - {share}
        uint256 feeShares = (supply * D18) / UD60x18.wrap(D18 - _tvlFee).powu(elapsed).unwrap() - supply;

        // D18{1} = D18{1/s} * D18 / D18{1/s}
        uint256 correction = (feeFloor * D18 + _tvlFee - 1) / _tvlFee;

        // {share} = {share} * D18{1} / D18
        uint256 daoShares = (correction > (daoFeeNumerator * D18 + daoFeeDenominator - 1) / daoFeeDenominator)
            ? (feeShares * correction + D18 - 1) / D18
            : (feeShares * daoFeeNumerator + daoFeeDenominator - 1) / daoFeeDenominator;

        _daoPendingFeeShares += daoShares;
        _feeRecipientsPendingFeeShares += feeShares - daoShares;
    }

    /// Set TVL fee by annual percentage. Different from how it is stored!
    /// @param _newFeeAnnually D18{1}
    function _setTVLFee(uint256 _newFeeAnnually) internal {
        require(_newFeeAnnually <= MAX_TVL_FEE, Folio__TVLFeeTooHigh());

        // convert annual percentage to per-second
        // = 1 - (1 - _newFeeAnnually) ^ (1 / 31536000)
        // D18{1/s} = D18{1} - D18{1} ^ {s}
        tvlFee = D18 - UD60x18.wrap(D18 - _newFeeAnnually).pow(ANNUALIZER).unwrap();

        require(_newFeeAnnually == 0 || tvlFee != 0, Folio__TVLFeeTooLow());

        emit TVLFeeSet(tvlFee, _newFeeAnnually);
    }

    /// Set mint fee
    /// @param _newFee D18{1}
    function _setMintFee(uint256 _newFee) internal {
        require(_newFee <= MAX_MINT_FEE, Folio__MintFeeTooHigh());

        mintFee = _newFee;
        emit MintFeeSet(_newFee);
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
        require(len <= MAX_FEE_RECIPIENTS, Folio__TooManyFeeRecipients());

        address previousRecipient;

        for (uint256 i; i < len; i++) {
            require(_feeRecipients[i].recipient > previousRecipient, Folio__FeeRecipientInvalidAddress());
            require(_feeRecipients[i].portion != 0, Folio__FeeRecipientInvalidFeeShare());

            total += _feeRecipients[i].portion;
            previousRecipient = _feeRecipients[i].recipient;
            feeRecipients.push(_feeRecipients[i]);
            emit FeeRecipientSet(_feeRecipients[i].recipient, _feeRecipients[i].portion);
        }

        // ensure table adds up to 100%
        require(total == D18, Folio__BadFeeTotal());
    }

    /// @param _newDelay {s}
    function _setAuctionDelay(uint256 _newDelay) internal {
        require(_newDelay <= MAX_AUCTION_DELAY, Folio__InvalidAuctionDelay());

        auctionDelay = _newDelay;
        emit AuctionDelaySet(_newDelay);
    }

    /// @param _newLength {s}
    function _setAuctionLength(uint256 _newLength) internal {
        require(_newLength >= MIN_AUCTION_LENGTH && _newLength <= MAX_AUCTION_LENGTH, Folio__InvalidAuctionLength());

        auctionLength = _newLength;
        emit AuctionLengthSet(auctionLength);
    }

    function _setMandate(string memory _newMandate) internal {
        mandate = _newMandate;
        emit MandateSet(_newMandate);
    }

    /// @dev After: daoPendingFeeShares and feeRecipientsPendingFeeShares are up-to-date
    function _poke() internal {
        if (lastPoke == block.timestamp) {
            return;
        }

        (daoPendingFeeShares, feeRecipientsPendingFeeShares) = _getPendingFeeShares();
        lastPoke = block.timestamp;
    }

    function _addToBasket(address token) internal returns (bool) {
        require(token != address(0), Folio__InvalidAsset());
        emit BasketTokenAdded(token);

        return basket.add(token);
    }

    function _removeFromBasket(address token) internal returns (bool) {
        emit BasketTokenRemoved(token);

        return basket.remove(token);
    }
}
