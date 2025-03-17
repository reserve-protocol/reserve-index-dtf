// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ITrustedFillerRegistry, IBaseTrustedFiller } from "@reserve-protocol/trusted-fillers/interfaces/ITrustedFillerRegistry.sol";

import { MathLib } from "@utils/MathLib.sol";
import { Versioned } from "@utils/Versioned.sol";

import { IBidderCallee } from "@interfaces/IBidderCallee.sol";
import { IFolioDAOFeeRegistry } from "@interfaces/IFolioDAOFeeRegistry.sol";
import { IFolio } from "@interfaces/IFolio.sol";

uint256 constant MAX_TVL_FEE = 0.1e18; // D18{1/year} 10% annually
uint256 constant MAX_MINT_FEE = 0.05e18; // D18{1} 5%
uint256 constant MIN_AUCTION_LENGTH = 60; // {s} 1 min
uint256 constant MAX_AUCTION_LENGTH = 604800; // {s} 1 week
uint256 constant MAX_AUCTION_DELAY = 604800; // {s} 1 week
uint256 constant MAX_FEE_RECIPIENTS = 64;
uint256 constant MAX_TTL = 604800 * 4; // {s} 4 weeks
uint256 constant MAX_RATE = 1e54; // D18{buyTok/sellTok}
uint256 constant MAX_PRICE_RANGE = 1e9; // {1}
uint256 constant RESTRICTED_AUCTION_BUFFER = 120; // {s} 2 min

uint256 constant ONE_OVER_YEAR = 31709791983; // D18{1/s} 1e18 / 31536000

uint256 constant D18 = 1e18; // D18
uint256 constant D27 = 1e27; // D27

/**
 * @title Folio
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Folio is a backed ERC20 token with permissionless minting/redemption and rebalancing via dutch auction
 *
 * A Folio is backed by a flexible number of ERC20 tokens of any denomination/price (within assumed ranges, see README)
 * All tokens tracked by the Folio are required to mint/redeem. This forms the basket.
 *
 * There are 3 main roles:
 *   1. DEFAULT_ADMIN_ROLE: can set erc20 assets, fees, auction length, auction delay, close auctions, and killFolio
 *   2. AUCTION_APPROVER: can approve auctions and close auctions
 *   3. AUCTION_LAUNCHER: can open auctions optionally providing some amount of additional detail, and close auctions
 *
 * There is also an additional BRAND_MANAGER role that does not have any permissions. It is used off-chain.
 *
 * Auction lifecycle:
 *   approveAuction() -> openAuction() -> bid() -> [optional] closeAuction()
 *
 * After an auction is first approved there is an `auctionDelay` before it can be opened by anyone. This provides
 * an isolated period of time where the AUCTION_LAUNCHER can open the auction, optionally providing additional pricing
 * and basket information within the pre-approved ranges.
 *
 * However, sometimes an auction may not fill. As long as it is before the `auction.launchDeadline` the auction can be
 * re-launched, up to the remaining number of `auction.availableRuns`. Between re-runs of the same auction, an
 * additional RESTRICTED_AUCTION_BUFFER (120s) is applied to give the AUCTION_LAUNCHER time to act first.
 *
 * An approved auction cannot block another approved auction from being opened. If an auction has been approved, then
 * it can be executed in parallel with any of the other approved auctions. Two auctions conflict on approval
 * if they share opposing tokens: if the sell token in one auction equals the buy token in the other.
 *
 * Rebalancing targets for auctions are defined in basket ratios: ratios of token to Folio shares, units D27{tok/share}
 *
 * Fees:
 *   - TVL fee: fee per unit time. Max 10% annually
 *   - Mint fee: fee on mint. Max 5%
 *
 * After fees have been applied, the DAO takes a cut based on the configuration of the FolioDAOFeeRegistry including
 * a minimum fee floor of 15bps. The remaining portion above 15bps is distributed to the Folio's fee recipients.
 * Note that this means it is possible for the fee recipients to receive nothing despite configuring a nonzero fee.
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
    bool public isKilled; // {bool} if true, Folio goes into redemption-only mode

    /**
     * Rebalancing
     *   APPROVED -> OPEN -> REOPENED N times (optional) -> CLOSED
     *   - Approved auctions have a `auctionDelay` before they can be opened that AUCTION_LAUNCHER can bypass
     *   - Approved auctions can always be opened together without conflict
     *   - Auctions can re-opened based on their `availableRuns` property
     *   - Multiple bids can be executed against the same auction
     *   - All auctions are dutch auctions with an exponential decay curve, but startPrice can equal endPrice
     */
    Auction[] public auctions;
    mapping(address token => uint256 timepoint) public sellEnds; // {s} timestamp of last possible second we could sell the token
    mapping(address token => uint256 timepoint) public buyEnds; // {s} timestamp of last possible second we could buy the token
    uint256 public auctionDelay; // {s} delay in the APPROVED state before an auction can be opened by anyone
    uint256 public auctionLength; // {s} length of an auction

    // === 2.0.0 ===
    mapping(uint256 auctionId => AuctionDetails details) public auctionDetails;
    mapping(address token => uint256 dustLimit) public dustLimits; // D27{tok/share}

    ITrustedFillerRegistry public trustedFillerRegistry;
    IBaseTrustedFiller private activeTrustedFill;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        FolioBasicDetails calldata _basicDetails,
        FolioAdditionalDetails calldata _additionalDetails,
        address _creator,
        address _daoFeeRegistry,
        address _trustedFillerRegistry
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
        _setTrustedFillerRegistry(_trustedFillerRegistry);

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

    /// @dev Enables removal of tokens if balance is below dust limit
    function removeFromBasket(IERC20 token) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _closeTrustedFill();

        // D27{tok/share} = {tok} * D27 / {share}
        uint256 basketPresence = Math.mulDiv(IERC20(token).balanceOf(address(this)), D27, totalSupply());

        require(basketPresence <= dustLimits[address(token)], Folio__BalanceNotDust());
        require(_removeFromBasket(address(token)), Folio__BasketModificationFailed());
    }

    /// @dev Set basket ratio at which tokens can be removed from basket
    /// @param newDustLimit D27{tok/share}
    function setDustLimit(address token, uint256 newDustLimit) external {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(AUCTION_APPROVER, msg.sender),
            Folio__Unauthorized()
        );
        _setDustLimit(token, newDustLimit);
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
    /// @dev Warning: An empty fee recipients table will result in all fees being sent to DAO
    function setFeeRecipients(FeeRecipient[] memory _newRecipients) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setFeeRecipients(_newRecipients);
    }

    /// @param _newDelay {s} Delay after a auction has been approved before it can be opened by anyone
    function setAuctionDelay(uint256 _newDelay) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAuctionDelay(_newDelay);
    }

    /// @param _newLength {s} Length of an auction
    function setAuctionLength(uint256 _newLength) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAuctionLength(_newLength);
    }

    /// @param _newMandate New mandate, a schelling point to guide governance
    function setMandate(string calldata _newMandate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMandate(_newMandate);
    }

    function setTrustedFillerRegistry(address _newFillerRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTrustedFillerRegistry(_newFillerRegistry);
    }

    /// Kill the Folio, callable only by the admin
    /// @dev Folio cannot be minted and auctions cannot be approved, opened, or bid on
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
    function totalAssets() public view returns (address[] memory _assets, uint256[] memory _amounts) {
        _assets = basket.values();

        uint256 assetLength = _assets.length;
        _amounts = new uint256[](assetLength);
        for (uint256 i; i < assetLength; i++) {
            _amounts[i] = IERC20(_assets[i]).balanceOf(address(this));

            if (address(activeTrustedFill) != address(0)) {
                _amounts[i] += IERC20(_assets[i]).balanceOf(address(activeTrustedFill));
            }
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

    /// @dev Use allowances to set slippage limits for provided assets
    /// @dev Minting has 3 share-portions: (i) receiver shares, (ii) DAO fee shares, (iii) fee recipients shares
    /// @param shares {share} Amount of shares to mint
    /// @param minSharesOut {share} Minimum amount of shares the caller must receive after fees
    /// @return _assets
    /// @return _amounts {tok}
    function mint(
        uint256 shares,
        address receiver,
        uint256 minSharesOut
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

        // {share}
        uint256 sharesOut = shares - totalFeeShares;
        require(sharesOut != 0 && sharesOut >= minSharesOut, Folio__InsufficientSharesOut());

        // === Transfer assets in ===

        (_assets, _amounts) = _toAssets(shares, Math.Rounding.Ceil);

        uint256 assetLength = _assets.length;
        for (uint256 i; i < assetLength; i++) {
            if (_amounts[i] != 0) {
                SafeERC20.safeTransferFrom(IERC20(_assets[i]), msg.sender, address(this), _amounts[i]);
            }
        }

        // === Mint shares ===

        _mint(receiver, sharesOut);

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
    /// @dev Recipients: DAO and fee recipients; if feeRecipients are empty, the DAO gets all the fees
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

    // ==== Auctions ====

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
        uint256 sellBal = auction.sellToken.balanceOf(address(this));
        uint256 buyBal = auction.buyToken.balanceOf(address(this));

        if (address(activeTrustedFill) != address(0)) {
            sellBal += auction.sellToken.balanceOf(address(activeTrustedFill));
            buyBal += auction.buyToken.balanceOf(address(activeTrustedFill));
        }

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
    ///     Must be >= auctionDelay if intended to be openly available
    ///     Set < auctionDelay to restrict launching to the AUCTION_LAUNCHER
    /// @param runs {runs} How many times the auction can be opened before it is permanently closed
    function approveAuction(
        IERC20 sell,
        IERC20 buy,
        BasketRange calldata sellLimit,
        BasketRange calldata buyLimit,
        Prices calldata prices,
        uint256 ttl,
        uint256 runs
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

        require(runs != 0, Folio__InvalidAuctionRuns());

        // do not buy and sell the same token simultaneously
        require(
            block.timestamp > sellEnds[address(buy)] && block.timestamp > buyEnds[address(sell)],
            Folio__AuctionCollision()
        );

        // {s}
        uint256 launchDeadline = block.timestamp + ttl;

        sellEnds[address(sell)] = Math.max(sellEnds[address(sell)], launchDeadline);
        buyEnds[address(buy)] = Math.max(buyEnds[address(buy)], launchDeadline);

        Auction memory auction = Auction({
            id: auctions.length,
            sellToken: sell,
            buyToken: buy,
            sellLimit: sellLimit,
            buyLimit: buyLimit,
            prices: Prices(0, 0),
            restrictedUntil: block.timestamp + auctionDelay,
            launchDeadline: launchDeadline,
            startTime: 0,
            endTime: 0,
            k: 0
        });
        auctions.push(auction);

        AuctionDetails memory details = AuctionDetails({ initialPrices: prices, availableRuns: runs });
        auctionDetails[auction.id] = details;

        emit AuctionApproved(auction.id, address(sell), address(buy), auction, details);
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
        AuctionDetails storage details = auctionDetails[auctionId];

        // auction launcher can:
        //   - select a sell limit within the approved range
        //   - select a buy limit within the approved range
        //   - raise starting price by up to 100x
        //   - raise ending price arbitrarily (can cause auction not to clear, same as closing auction)

        require(
            startPrice >= details.initialPrices.start &&
                endPrice >= details.initialPrices.end &&
                (details.initialPrices.start == 0 || startPrice <= 100 * details.initialPrices.start),
            Folio__InvalidPrices()
        );

        require(sellLimit >= auction.sellLimit.low && sellLimit <= auction.sellLimit.high, Folio__InvalidSellLimit());

        require(buyLimit >= auction.buyLimit.low && buyLimit <= auction.buyLimit.high, Folio__InvalidBuyLimit());

        auction.sellLimit.spot = sellLimit;
        auction.buyLimit.spot = buyLimit;
        auction.prices.start = startPrice;
        auction.prices.end = endPrice;
        // more price checks in _openAuction()

        _openAuction(auction, details, 0);
    }

    /// Open an auction without restrictions
    /// @dev Unrestricted, callable only after the `auctionDelay`
    function openAuctionUnrestricted(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        AuctionDetails storage details = auctionDetails[auctionId];

        // only open auctions that are unrestricted
        require(block.timestamp >= auction.restrictedUntil, Folio__AuctionCannotBeOpenedWithoutRestriction());

        auction.prices = details.initialPrices;
        // more price checks in _openAuction()

        _openAuction(auction, details, RESTRICTED_AUCTION_BUFFER);
    }

    /// Bid in an ongoing auction
    ///   If withCallback is true, caller must adhere to IBidderCallee interface and receives a callback
    ///   If withCallback is false, caller must have provided an allowance in advance
    /// @dev Callable by anyone
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
        _closeTrustedFill();

        Auction storage auction = auctions[auctionId];

        // stack-too-deep
        {
            // checks auction is ongoing
            // D27{buyTok/sellTok}
            uint256 price = _price(auction, block.timestamp);

            // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
            boughtAmt = Math.mulDiv(sellAmount, price, D27, Math.Rounding.Ceil);
            require(boughtAmt <= maxBuyAmount, Folio__SlippageExceeded());
        }

        // totalSupply inflates over time due to TVL fee, causing buyLimits/sellLimits to be slightly stale
        uint256 _totalSupply = totalSupply();

        // checks auction is ongoing and that sellAmount/maxBuyAmount are valid/met
        boughtAmt = _getBid(auction, _totalSupply, block.timestamp, sellAmount, maxBuyAmount);

        // pay bidder
        auction.sellToken.safeTransfer(msg.sender, sellAmount);

        emit AuctionBid(auctionId, sellAmount, boughtAmt);

        // D27{sellTok/share} = {sellTok} * D27 / {share}
        uint256 sellBasketPresence = Math.mulDiv(auction.sellToken.balanceOf(address(this)), D27, _totalSupply);

        // remove sell token from basket once below dust limit and end auction
        if (sellBasketPresence <= dustLimits[address(auction.sellToken)]) {
            auction.endTime = block.timestamp - 1;
            auctionDetails[auctionId].availableRuns = 0;

            _removeFromBasket(address(auction.sellToken));
        }

        // collect payment from bidder
        if (withCallback) {
            uint256 balBefore = auction.buyToken.balanceOf(address(this));

            IBidderCallee(msg.sender).bidCallback(address(auction.buyToken), boughtAmt, data);

            require(auction.buyToken.balanceOf(address(this)) - balBefore >= boughtAmt, Folio__InsufficientBid());
        } else {
            auction.buyToken.safeTransferFrom(msg.sender, address(this), boughtAmt);
        }

        // D27{buyTok/share} = D27{buyTok/share} * {share} / D27
        uint256 maxBuyBal = Math.mulDiv(auction.buyLimit.spot, _totalSupply, D27, Math.Rounding.Floor);

        // ensure post-bid buy balance does not exceed max
        require(auction.buyToken.balanceOf(address(this)) <= maxBuyBal, Folio__ExcessiveBid());
    }

    /// As an alternative to bidding directly, an in-block async swap can be opened without removing Folio's access
    function createTrustedFiller(
        uint256 auctionId,
        uint256 sellAmount, // TODO: Trusted fills can be partial, so we should remove this entirely.
        uint256 buyAmount,
        address targetFiller,
        bytes32 deploymentSalt
    ) external nonReentrant returns (IBaseTrustedFiller filler) {
        require(!isKilled, Folio__FolioKilled());
        require(address(trustedFillerRegistry) != address(0), Folio__TrustedFillerRegistryNotSet());

        Auction storage auction = auctions[auctionId];
        _closeTrustedFill();

        // checks auction is ongoing and sellAmount and buyAmount are valid
        _getBid(auction, totalSupply(), block.timestamp, sellAmount, buyAmount);

        // Create Trusted Filler
        filler = trustedFillerRegistry.createTrustedFiller(msg.sender, targetFiller, deploymentSalt);
        auction.sellToken.forceApprove(address(filler), sellAmount);

        filler.initialize(address(this), auction.sellToken, auction.buyToken, sellAmount, buyAmount);
        activeTrustedFill = filler;

        emit AuctionTrustedFillCreated(auctionId, address(filler));
    }

    /// Close an auction
    /// A auction can be closed from anywhere in its lifecycle, and cannot be restarted
    /// @dev Callable by ADMIN or AUCTION_APPROVER or AUCTION_LAUNCHER
    function closeAuction(uint256 auctionId) external nonReentrant {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                hasRole(AUCTION_APPROVER, msg.sender) ||
                hasRole(AUCTION_LAUNCHER, msg.sender),
            Folio__Unauthorized()
        );

        // do not revert, to prevent griefing
        auctions[auctionId].endTime = block.timestamp - 1;
        auctionDetails[auctionId].availableRuns = 0;

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

        (_assets, _amounts) = totalAssets();

        uint256 assetLen = _assets.length;
        for (uint256 i; i < assetLen; i++) {
            // {tok} = {share} * {tok} / {share}
            _amounts[i] = Math.mulDiv(shares, _amounts[i], _totalSupply, rounding);
        }
    }

    /// @param buffer {s} Additional time buffer that must pass from `endTime` before auction can be opened
    function _openAuction(Auction storage auction, AuctionDetails storage details, uint256 buffer) internal {
        require(!isKilled, Folio__FolioKilled());

        // only open APPROVED or expired auctions, with buffer
        require(block.timestamp > auction.endTime + buffer, Folio__AuctionCannotBeOpenedYet());

        // do not open auctions that have timed out from ttl
        require(block.timestamp <= auction.launchDeadline, Folio__AuctionTimeout());

        // {s}
        uint256 endTime = block.timestamp + auctionLength;

        sellEnds[address(auction.sellToken)] = Math.max(sellEnds[address(auction.sellToken)], endTime);
        buyEnds[address(auction.buyToken)] = Math.max(buyEnds[address(auction.buyToken)], endTime);

        // ensure valid price range (startPrice == endPrice is valid)
        require(
            auction.prices.start >= auction.prices.end &&
                auction.prices.end != 0 &&
                auction.prices.start <= MAX_RATE &&
                auction.prices.start / auction.prices.end <= MAX_PRICE_RANGE,
            Folio__InvalidPrices()
        );

        // ensure auction has enough runs remaining
        require(details.availableRuns != 0, Folio__InvalidAuctionRuns());
        unchecked {
            details.availableRuns--;
        }

        auction.startTime = block.timestamp;
        auction.endTime = endTime;

        // ensure buy token is in basket since swaps can happen out-of-band
        _addToBasket(address(auction.buyToken));
        emit AuctionOpened(auction.id, auction, details.availableRuns);

        // D18{1}
        // k = ln(P_0 / P_t) / t
        auction.k = MathLib.ln((auction.prices.start * D18) / auction.prices.end) / auctionLength;
        // gas optimization to avoid recomputing k on every bid
    }

    /// @return p D27{buyTok/sellTok}
    function _price(Auction storage auction, uint256 timestamp) internal view returns (uint256 p) {
        // ensure auction is ongoing
        require(timestamp >= auction.startTime && timestamp <= auction.endTime, Folio__AuctionNotOngoing());

        if (timestamp == auction.startTime) {
            return auction.prices.start;
        }
        if (timestamp == auction.endTime) {
            return auction.prices.end;
        }

        uint256 elapsed = timestamp - auction.startTime;

        // P_t = P_0 * e ^ -kt
        // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
        p = (auction.prices.start * MathLib.exp(-1 * int256(auction.k * elapsed))) / D18;
        if (p < auction.prices.end) {
            p = auction.prices.end;
        }
    }

    /// @dev Check auction is ongoing and that sellAmount/maxBuyAmount are valid/met
    /// @return bidAmount {buyTok} The buy amount corresponding to the sell amount
    function _getBid(
        Auction storage auction,
        uint256 _totalSupply,
        uint256 timestamp,
        uint256 sellAmount,
        uint256 maxBuyAmount
    ) internal view returns (uint256 bidAmount) {
        // checks auction is ongoing
        // D27{buyTok/sellTok}
        uint256 price = _price(auction, timestamp);

        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        bidAmount = Math.mulDiv(sellAmount, price, D27, Math.Rounding.Ceil);
        require(bidAmount <= maxBuyAmount && bidAmount != 0, Folio__SlippageExceeded());

        uint256 sellBal = auction.sellToken.balanceOf(address(this));

        // {sellTok} = D27{sellTok/share} * {share} / D27
        uint256 minSellBal = Math.mulDiv(auction.sellLimit.spot, _totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = sellBal > minSellBal ? sellBal - minSellBal : 0;

        // ensure auction is large enough to cover bid
        require(sellAmount <= sellAvailable && sellAmount != 0, Folio__InsufficientBalance());
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
        uint256 feeFloor = D18 - MathLib.pow(D18 - daoFeeFloor, ONE_OVER_YEAR);

        // D18{1/s}
        uint256 _tvlFee = feeFloor > tvlFee ? feeFloor : tvlFee;

        // {share} += {share} * D18 / D18{1/s} ^ {s} - {share}
        uint256 feeShares = (supply * D18) / MathLib.powu(D18 - _tvlFee, elapsed) - supply;

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
        tvlFee = D18 - MathLib.pow(D18 - _newFeeAnnually, ONE_OVER_YEAR);

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

    /// @dev Warning: An empty fee recipients table will result in all fees being sent to DAO
    function _setFeeRecipients(FeeRecipient[] memory _feeRecipients) internal {
        emit FeeRecipientsSet(_feeRecipients);

        // Clear existing fee table
        uint256 len = feeRecipients.length;
        for (uint256 i; i < len; i++) {
            feeRecipients.pop();
        }

        // Add new items to the fee table
        len = _feeRecipients.length;

        if (len == 0) {
            return;
        }

        require(len <= MAX_FEE_RECIPIENTS, Folio__TooManyFeeRecipients());

        address previousRecipient;
        uint256 total;

        for (uint256 i; i < len; i++) {
            require(_feeRecipients[i].recipient > previousRecipient, Folio__FeeRecipientInvalidAddress());
            require(_feeRecipients[i].portion != 0, Folio__FeeRecipientInvalidFeeShare());

            total += _feeRecipients[i].portion;
            previousRecipient = _feeRecipients[i].recipient;
            feeRecipients.push(_feeRecipients[i]);
        }

        // ensure table adds up to 100%
        require(total == D18, Folio__BadFeeTotal());
    }

    /// @dev Overrules RESTRICTED_AUCTION_BUFFER on first auction run
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

    /// @param newDustLimit D27{tok/share}
    function _setDustLimit(address token, uint256 newDustLimit) internal {
        dustLimits[token] = newDustLimit;
        emit DustLimitSet(token, newDustLimit);
    }

    function _setMandate(string memory _newMandate) internal {
        mandate = _newMandate;
        emit MandateSet(_newMandate);
    }

    /// @dev After: daoPendingFeeShares and feeRecipientsPendingFeeShares are up-to-date
    function _poke() internal {
        _closeTrustedFill();

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

    function _setTrustedFillerRegistry(address _newFillerRegistry) internal {
        require(address(trustedFillerRegistry) == address(0), Folio__TrustedFillerRegistryAlreadySet());

        trustedFillerRegistry = ITrustedFillerRegistry(_newFillerRegistry);

        emit TrustedFillerRegistrySet(_newFillerRegistry);
    }

    /// Claim all token balances from outstanding trusted fill
    function _closeTrustedFill() internal {
        if (address(activeTrustedFill) != address(0)) {
            activeTrustedFill.closeFiller();
            delete activeTrustedFill;
        }
    }
}
