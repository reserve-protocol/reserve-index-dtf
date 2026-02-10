// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ITrustedFillerRegistry, IBaseTrustedFiller } from "@reserve-protocol/trusted-fillers/contracts/interfaces/ITrustedFillerRegistry.sol";

import { RebalancingLib } from "@utils/RebalancingLib.sol";
import { FolioLib } from "@utils/FolioLib.sol";
import { AUCTION_WARMUP, AUCTION_LAUNCHER, D18, D27, ERC20_STORAGE_LOCATION, REBALANCE_MANAGER, MAX_MINT_FEE, MAX_FOLIO_FEE, MIN_AUCTION_LENGTH, MAX_AUCTION_LENGTH, RESTRICTED_AUCTION_BUFFER, ONE_DAY } from "@utils/Constants.sol";
import { Versioned } from "@utils/Versioned.sol";

import { IFolioDAOFeeRegistry } from "@interfaces/IFolioDAOFeeRegistry.sol";
import { IFolio } from "@interfaces/IFolio.sol";

/**
 * @title Folio
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Folio is a backed ERC20 token with permissionless minting/redemption and a semi-permissioned rebalancing
 *   mechanism intended for rebalancing under timelock delay.
 *
 * A Folio is backed by a flexible number of ERC20 tokens of any denomination/price (within assumed ranges, see README)
 *   All tokens tracked by the Folio are required to mint/redeem. This forms the basket.
 *
 * There are 3 main roles:
 *   1. DEFAULT_ADMIN_ROLE: can set erc20 assets, fees, auction length, close auctions/rebalances, and deprecateFolio
 *   2. REBALANCE_MANAGER: can start/end rebalances, and end individual auctions
 *   3. AUCTION_LAUNCHER: can open auctions and end rebalances/auctions
 *
 * There is also an additional BRAND_MANAGER role that does not have any permissions. It is for off-chain use.
 *
 * AUCTION_LAUNCHER assumptions:
 *   - SHOULD NOT close auctions/rebalances to deny the rebalance dishonestly
 *   - SHOULD craft auctions against progressively narrowed BU limits to responsibly DCA into the new basket
 *   - SHOULD end the ongoing rebalance when prices have moved outside the initially-provided price ranges
 *   - if weightControl=true: SHOULD progressively narrow weight ranges to maintain the original rebalance intent
 *   - if priceControl=PARTIAL: SHOULD provide narrowed price ranges that still include the current clearing price
 *        priceControl=ATOMIC_SWAP: SHOULD fill auction atomically directly after opening AND end rebalance after
 *
 * Rebalance lifecycle:
 *   startRebalance() -> openAuction()/openAuctionUnrestricted() -> bid()/createTrustedFill() -> [optional] closeAuction()
 *
 * After a new rebalance is started by the REBALANCE_MANAGER, there is a period of time where only the AUCTION_LAUNCHER
 * can run auctions. They can specify a few different things:
 *   - The list of tokens to include in the auction; must be a subset of the tokens in the rebalance
 *   - Basket weight ranges: can progressively tighten the basket weight ranges, without backtracking
 *   - Individual token price ranges: can be a subset of the initially-provided range, if priceControl!=NONE
 *   - Rebalance limits: can progressively tighten the BU limits, without backtracking
 *
 * The AUCTION_LAUNCHER can run as many auctions as they need to. If they are close to the end of their restricted
 *   period the period will be extended automatically until a period of non-use occurs. However, they cannot extend the
 *   period indefinitely past the rebalance's end time. The final auction may extend past the rebalance's endTime, however.
 *
 * After the AUCTION_LAUNCHER's restricted period is over, anyone can open auctions until the rebalance expires. The
 *   AUCTION_LAUNCHER can always deny the unrestricted period by ending the rebalance when they are done.
 *
 * The unrestricted period exists primarily to avoid strong reliance on the AUCTION_LAUNCHER. The auctionLength should be
 *   long enough to support the price ranges provided by REBALANCE_MANAGER without excessive loss due to block precision
 *   in the case the AUCTION_LAUNCHER is not active.
 *
 * Auctions have a 30s delay at-start before bidding begins in order to ensure competition from the first block. This delay
 *   is bypassed in the priceControl=ATOMIC_SWAP case when startPrices are equal to endPrices.
 *
 * An auction for a set of tokens runs in parallel on all possible pairs simultaneously. The current price for each
 *   pair is interpolated along an exponential decay curve between their most-optimistic and most-pessimistic price
 *   estimates as a function of how much time in the auction has passed.
 *
 * In order for a pair to be eligible for an auction, the sell token must be in surplus and the buy token in deficit,
 *   as defined by balances relative to the (i) surplus: high weight * high BU limit; and (ii) deficit: low weight *
 *   low basket limit. Individual token weights can also be used to handle rebalancing independent of BU limits
 *   when the ideal relative ratios of token units is not known ahead of time.
 *
 * A Basket Unit {BU} can be defined within a (0, 1e27] range, but the typical usage defines BUs 1:1 with shares (1e18).
 *
 * Fees:
 *   - TVL fee: fee per unit time. Max 10% annually. Causes supply inflation over time, discretely once a day.
 *   - Mint fee: fee on mint. Max 5%. Does not cause supply inflation.
 *
 * After fees have been applied, the DAO takes a cut based on the configuration of the FolioDAOFeeRegistry including
 *   a minimum fee floor of 15bps. The remaining portion above 15bps is distributed to the Folio's fee recipients.
 *   Note that this means it is possible for the fee recipients to receive nothing despite configuring a nonzero fee.
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

    /**
     * Roles
     *
     * bytes32 constant REBALANCE_MANAGER = keccak256("REBALANCE_MANAGER"); // expected to be trading governance's timelock
     * bytes32 constant AUCTION_LAUNCHER = keccak256("AUCTION_LAUNCHER"); // optional: EOA or multisig
     * bytes32 constant BRAND_MANAGER = keccak256("BRAND_MANAGER"); // optional: no permissions
     */

    IFolioDAOFeeRegistry public daoFeeRegistry;

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
    bool public isDeprecated; // {bool} if true, Folio goes into redemption-only mode

    modifier notDeprecated() {
        require(!isDeprecated, Folio__FolioDeprecated());
        _;
    }

    DeprecatedStruct[] private auctions_DEPRECATED;
    mapping(address token => uint256 timepoint) private sellEnds_DEPRECATED;
    mapping(address token => uint256 timepoint) private buyEnds_DEPRECATED;
    uint256 private auctionDelay_DEPRECATED;

    uint256 public auctionLength; // {s} length of an auction

    // === 2.0.0 ===
    mapping(uint256 auctionId => DeprecatedStruct details) private auctionDetails_DEPRECATED;
    mapping(address token => uint256 amount) private dustAmount_DEPRECATED;

    // === 3.0.0 ===
    ITrustedFillerRegistry public trustedFillerRegistry;
    bool public trustedFillerEnabled;
    IBaseTrustedFiller private activeTrustedFill;

    // === 4.0.0 ===
    // 3.0.0 release was skipped so strict 3.0.0 -> 4.0.0 storage compatibility is not a requirement

    RebalanceControl public rebalanceControl; // AUCTION_LAUNCHER control over rebalancing

    /**
     * Rebalancing
     *   REBALANCE_MANAGER
     *   - There can be any number of auctions within a rebalance, but only one live at a time
     *   - Auctions are restricted to the AUCTION_LAUNCHER until rebalance.restrictedUntil, with possible extensions
     *   - Auctions cannot be launched after availableUntil, though their start/end times may extend past it
     *   - Each auction the AUCTION_LAUNCHER provides: (i) basket limits; (i) weight ranges; and (iii) prices
     *   - Depending on the WeightControl, the AUCTION_LAUNCHER may be able to narrow weight ranges within the initial range
     *   - Depending on the PriceControl, the AUCTION_LAUNCHER may be able to narrow prices within the initial range
     *   - At anytime the rebalance can be stopped or a new one can be started. In the stopping case, any ongoing auction
     *     is able to continue completion, but in the restart case the ongoing auction is closed.
     */
    Rebalance private rebalance;

    /**
     * Auctions
     *   Openable by AUCTION_LAUNCHER -> Openable by anyone (optional) -> Warmup (30s) -> Running -> Closed
     *   - An auction is in parallel on all surplus/deficit token pairs at the same time
     *   - Bids are of any size, up to a maximum given by the high/low basket limits and high/low token weights
     *   - All auctions are dutch auctions with an exponential decay curve between two points
     *   - The warmup period is bypassed in the priceControl=ATOMIC_SWAP case when startPrices are equal to endPrices
     */
    mapping(uint256 id => Auction auction) public auctions;
    uint256 public nextAuctionId;

    // === 5.0.0 ===
    bool public bidsEnabled;

    // === 6.0.0 ===
    bool public tradeAllowlistEnabled;
    EnumerableSet.AddressSet private tradeTokenAllowlist;
    uint256 public folioFeeForSelf; // D18{1} fraction of fee-recipient shares to burn

    /// Any external call to the Folio that relies on accurate share accounting must pre-hook poke
    modifier sync() {
        _poke();
        _;
    }

    // ====

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        FolioBasicDetails calldata _basicDetails,
        FolioAdditionalDetails calldata _additionalDetails,
        FolioRegistryIndex calldata _folioRegistries,
        FolioFlags calldata _folioFlags,
        address _creator
    ) external initializer {
        __ERC20_init(_basicDetails.name, _basicDetails.symbol);
        __AccessControlEnumerable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        FolioLib.setFeeRecipients(feeRecipients, _additionalDetails.feeRecipients);
        _setTVLFee(_additionalDetails.tvlFee);
        _setMintFee(_additionalDetails.mintFee);
        _setFolioSelfFee(_additionalDetails.folioFeeForSelf);
        _setAuctionLength(_additionalDetails.auctionLength);
        _setMandate(_additionalDetails.mandate);

        _setRebalanceControl(_folioFlags.rebalanceControl);
        _setBidsEnabled(_folioFlags.bidsEnabled);

        _setTrustedFillerRegistry(_folioRegistries.trustedFillerRegistry, _folioFlags.trustedFillerEnabled);
        _setDaoFeeRegistry(_folioRegistries.daoFeeRegistry);

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

    function poke() external nonReentrant {
        _poke();
    }

    /// Check if the Folio state can be relied upon to be complete
    /// @dev Safety check for consuming protocols to check for synchronous and asynchronous state changes
    /// @dev Consuming protocols SHOULD call this function and ensure it returns (false, false) before
    ///      strongly relying on the Folio state. The asyncStateChangeActive check can be DoS'd for the current block.
    function stateChangeActive() external view returns (bool syncStateChangeActive, bool asyncStateChangeActive) {
        syncStateChangeActive = _reentrancyGuardEntered();
        asyncStateChangeActive = address(activeTrustedFill) != address(0) && activeTrustedFill.swapActive();
    }

    // ==== Allowlist ====

    /// @return The list of tokens currently on the allowlist
    function getTokenAllowlist() external view returns (address[] memory) {
        return tradeTokenAllowlist.values();
    }

    /// @param token The token to check
    /// @return True if the token is on the allowlist
    function isTokenAllowlisted(address token) external view returns (bool) {
        return tradeTokenAllowlist.contains(token);
    }

    // ==== Governance ====

    /// Escape hatch function to be used when tokens get acquired not through an auction but
    /// through any other means and should become part of the Folio without being sold.
    /// @dev Does not require a token balance, hence can be backrun with removeFromBasket. Token
    ///      balance is highly recommended.
    /// @param token The token to add to the basket
    function addToBasket(IERC20 token) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_addToBasket(address(token)), Folio__BasketModificationFailed());
    }

    /// @dev Enables permissionless removal of tokens for 0 balance tokens
    function removeFromBasket(IERC20 token) external nonReentrant {
        _closeTrustedFill();

        // always allow admin to remove from basket
        // allow permissionless removal if 0 weight AND 0 balance
        // known: can be griefed by token donation
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                (rebalance.details[address(token)].weights.spot == 0 && IERC20(token).balanceOf(address(this)) == 0),
            Folio__BalanceNotRemovable()
        );
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

    /// Set the folio fee — fraction of fee-recipient shares that are burned (not minted)
    /// @dev Non-reentrant via distributeFees()
    /// @param _newFee D18{1} Fraction of fee-recipient shares to burn
    function setFolioSelfFee(uint256 _newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setFolioSelfFee(_newFee);
    }

    /// @dev Non-reentrant via distributeFees()
    /// @dev Fee recipients must be unique and sorted by address, and sum to 1e18
    /// @dev Warning: An empty fee recipients table will result in all fees being sent to DAO
    function setFeeRecipients(FeeRecipient[] calldata _newRecipients) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        FolioLib.setFeeRecipients(feeRecipients, _newRecipients);
    }

    /// @param _newLength {s} Length of an auction
    function setAuctionLength(uint256 _newLength) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAuctionLength(_newLength);
    }

    /// @param _newMandate New mandate, a schelling point to guide governance
    function setMandate(string calldata _newMandate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMandate(_newMandate);
    }

    /// @param _newName New token name
    function setName(string calldata _newName) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setName(_newName);
    }

    /// @dev _newFillerRegistry must be the already set registry if already set. This is to ensure
    ///      correctness and in order to be explicit what registry is being enabled/disabled.
    function setTrustedFillerRegistry(address _newFillerRegistry, bool _enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTrustedFillerRegistry(_newFillerRegistry, _enabled);
    }

    /// @dev Does not impact ongoing rebalances
    /// @param _rebalanceControl.weightControl If AUCTION_LAUNCHER can move weights
    /// @param _rebalanceControl.priceControl How the AUCTION_LAUNCHER can manipulate prices, if at all
    function setRebalanceControl(RebalanceControl calldata _rebalanceControl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRebalanceControl(_rebalanceControl);
    }

    /// @param _bidsEnabled If true, permissionless bids are enabled
    function setBidsEnabled(bool _bidsEnabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setBidsEnabled(_bidsEnabled);
    }

    /// @param _enabled If true, token allowlist is enforced during rebalancing
    function setTradeAllowlistEnabled(bool _enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTradeAllowlistEnabled(_enabled);
    }

    /// Add tokens to the allowlist
    /// @param tokens The tokens to add to the allowlist
    function addToAllowlist(address[] calldata tokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = tokens.length;
        for (uint256 i; i < len; i++) {
            if (tradeTokenAllowlist.add(tokens[i])) {
                emit TradeAllowlistTokenAdded(tokens[i]);
            }
        }
    }

    /// Remove tokens from the allowlist
    /// @param tokens The tokens to remove from the allowlist
    function removeFromAllowlist(address[] calldata tokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = tokens.length;
        for (uint256 i; i < len; i++) {
            if (tradeTokenAllowlist.remove(tokens[i])) {
                emit TradeAllowlistTokenRemoved(tokens[i]);
            }
        }
    }

    /// Deprecate the Folio, callable only by the admin
    /// @dev Folio cannot be minted and auctions cannot be approved, opened, or bid on
    function deprecateFolio() external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        isDeprecated = true;

        emit FolioDeprecated();
    }

    // ==== Share + Asset Accounting ====

    /// @dev Contains all pending fee shares
    function totalSupply() public view override returns (uint256) {
        (uint256 _daoPendingFeeShares, uint256 _feeRecipientsPendingFeeShares, ) = _getPendingFeeShares();

        return super.totalSupply() + _daoPendingFeeShares + _feeRecipientsPendingFeeShares;
    }

    /// @dev Result may be unreliable mid-swap during trusted fill execution, check stateChangeActive()
    /// @return _assets
    /// @return _amounts {tok}
    function totalAssets() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        return _totalAssets();
    }

    /// @dev Result may be unreliable mid-swap during trusted fill execution, check stateChangeActive()
    /// @param shares {share}
    /// @return _assets
    /// @return _amounts {tok}
    function toAssets(
        uint256 shares,
        Math.Rounding rounding
    ) external view returns (address[] memory _assets, uint256[] memory _amounts) {
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
    ) external nonReentrant notDeprecated sync returns (address[] memory _assets, uint256[] memory _amounts) {
        // === Calculate fee shares ===

        (uint256 sharesOut, uint256 daoFeeShares, uint256 feeRecipientFeeShares) = FolioLib.computeMintFees(
            FolioLib.MintFeeParams({
                shares: shares,
                mintFee: mintFee,
                folioFeeForSelf: folioFeeForSelf,
                minSharesOut: minSharesOut
            }),
            daoFeeRegistry
        );

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
        feeRecipientsPendingFeeShares += feeRecipientFeeShares;
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
    ) external nonReentrant sync returns (uint256[] memory _amounts) {
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
        (uint256 _daoPendingFeeShares, uint256 _feeRecipientsPendingFeeShares, ) = _getPendingFeeShares();
        return _daoPendingFeeShares + _feeRecipientsPendingFeeShares;
    }

    /// Distribute all pending fee shares
    /// @dev Recipients: DAO and fee recipients; if feeRecipients are empty, the DAO gets all the fees
    /// @dev Pending fee shares are already reflected in the total supply, this function only concretizes balances
    function distributeFees() public nonReentrant sync {
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

    /// Get the price of a token in an auction
    function getAuctionPrice(uint256 auctionId, address token) external view returns (PriceRange memory range) {
        range = auctions[auctionId].prices[token];
        require(range.low != 0, Folio__InvalidAsset());
    }

    /// @dev stack-too-deep
    struct RebalanceTimestamps {
        uint256 startedAt; // {s} timestamp rebalancing started, inclusive
        uint256 restrictedUntil; // {s} timestamp rebalancing becomes unrestricted, exclusive
        uint256 availableUntil; // {s} timestamp rebalancing ends overall, exclusive
    }

    /// Get the currently ongoing rebalance
    /// @dev Nonzero return values do not imply a rebalance is ongoing; check `rebalance.availableUntil`
    /// @return nonce The current rebalance nonce
    /// @return priceControl How much price control the AUCTION_LAUNCHER has: [NONE, PARTIAL, ATOMIC_SWAP]
    /// @return tokens The rebalance parameters for each token in the basket
    /// @return limits D18{BU/share} The current target limits for rebalancing
    /// @return timestamps {s} The timestamps for the rebalance
    /// @return bidsEnabled_ If true, permissionless bids are enabled for this rebalance
    function getRebalance()
        external
        view
        returns (
            uint256 nonce,
            PriceControl priceControl,
            TokenRebalanceParams[] memory tokens,
            RebalanceLimits memory limits,
            RebalanceTimestamps memory timestamps,
            bool bidsEnabled_
        )
    {
        nonce = rebalance.nonce;
        priceControl = rebalance.priceControl;

        address[] memory basketTokens = basket.values();
        uint256 len = basketTokens.length;

        tokens = new TokenRebalanceParams[](len);

        for (uint256 i; i < len; i++) {
            address token = basketTokens[i];
            RebalanceDetails storage details = rebalance.details[token];

            tokens[i] = TokenRebalanceParams({
                token: token,
                weight: details.weights,
                price: details.initialPrices,
                maxAuctionSize: details.maxAuctionSize,
                inRebalance: details.inRebalance
            });
        }

        limits = rebalance.limits;

        timestamps = RebalanceTimestamps({
            startedAt: rebalance.startedAt,
            restrictedUntil: rebalance.restrictedUntil,
            availableUntil: rebalance.availableUntil
        });

        bidsEnabled_ = rebalance.bidsEnabled;
    }

    /// Start a new rebalance, ending the currently running auction
    /// @dev If caller omits old tokens they will be kept in the basket for mint/redeem but skipped in the rebalance
    /// @dev Note that weights will be _slightly_ stale after the fee supply inflation on a 24h boundary
    /// @param tokens The rebalance parameters for each token in the rebalance
    /// @param tokens.token MUST be unique
    /// @param tokens.weight D27{tok/BU} Basket weight ranges; cannot be empty [0, 1e54]
    /// @param tokens.price D27{UoA/tok} Prices for each token; cannot be empty (0, 1e45]
    /// @param tokens.maxAuctionSize {tok} Max amount to sell in any single auction
    /// @param tokens.inRebalance MUST be true
    /// @param limits D18{BU/share} Target number of baskets should have at end of rebalance (0, 1e27]
    /// @param auctionLauncherWindow {s} The amount of time the AUCTION_LAUNCHER has to open auctions, can be extended
    /// @param ttl {s} The amount of time the rebalance is valid for
    function startRebalance(
        TokenRebalanceParams[] calldata tokens,
        RebalanceLimits calldata limits,
        uint256 auctionLauncherWindow,
        uint256 ttl
    ) external onlyRole(REBALANCE_MANAGER) nonReentrant notDeprecated sync {
        // enforce token allowlist: non-allowlisted tokens can only be traded out (zero weights)
        if (tradeAllowlistEnabled) {
            for (uint256 i; i < tokens.length; i++) {
                if (!tradeTokenAllowlist.contains(tokens[i].token)) {
                    require(
                        tokens[i].weight.low == 0 && tokens[i].weight.spot == 0 && tokens[i].weight.high == 0,
                        Folio__TokenNotAllowlisted()
                    );
                }
            }
        }

        RebalancingLib.startRebalance(
            basket.values(),
            rebalanceControl,
            rebalance,
            tokens,
            limits,
            auctionLauncherWindow,
            ttl,
            bidsEnabled
        );

        // add new tokens to basket
        for (uint256 i; i < tokens.length; i++) {
            _addToBasket(tokens[i].token);
        }
    }

    /// Open an auction as the AUCTION_LAUNCHER aimed at specific BU limits and weights, for a given set of tokens
    /// @param rebalanceNonce The nonce of the rebalance being targeted
    /// @param tokens The tokens from the rebalance to include in the auction; must be unique
    /// @param newWeights D27{tok/BU} New basket weight ranges for BU definition; must always be provided
    /// @param newPrices D27{UoA/tok} New price ranges; must always be provided and obey PriceControl setting
    /// @param newLimits D18{BU/share} New BU limits; must be within range
    /// @return auctionId The newly created auctionId
    function openAuction(
        uint256 rebalanceNonce,
        address[] calldata tokens,
        WeightRange[] calldata newWeights,
        PriceRange[] calldata newPrices,
        RebalanceLimits calldata newLimits
    ) external onlyRole(AUCTION_LAUNCHER) nonReentrant notDeprecated sync returns (uint256 auctionId) {
        // require tokens are in the rebalance
        uint256 len = tokens.length;
        for (uint256 i; i < len; i++) {
            require(rebalance.details[tokens[i]].inRebalance, Folio__InvalidAsset());
        }

        // open an auction on the provided limits, weights, and prices
        auctionId = _openAuction(rebalanceNonce, tokens, newWeights, newPrices, newLimits, 0);

        // bump rebalance deadlines to ensure an opportunity for the AUCTION_LAUNCHER to act again
        // can potentially send the rebalance from the unrestricted period back into the restricted period
        rebalance.restrictedUntil = Math.max(
            rebalance.restrictedUntil,
            block.timestamp + auctionLength + AUCTION_WARMUP + RESTRICTED_AUCTION_BUFFER + 1
        );
    }

    /// Open an auction without caller restrictions, on all tokens in the rebalance on spot values and initial prices
    /// @dev Callable only after the auction launcher window passes, and when no other auction is ongoing
    /// @return auctionId The newly created auctionId
    function openAuctionUnrestricted(
        uint256 rebalanceNonce
    ) external nonReentrant notDeprecated sync returns (uint256 auctionId) {
        require(block.timestamp >= rebalance.restrictedUntil, Folio__AuctionCannotBeOpenedWithoutRestriction());

        address[] memory basketTokens = basket.values();
        uint256 len = basketTokens.length;

        // count tokens in rebalance
        uint256 count;
        for (uint256 i; i < len; i++) {
            if (rebalance.details[basketTokens[i]].inRebalance) {
                count++;
            }
        }

        address[] memory tokens = new address[](count);
        WeightRange[] memory weights = new WeightRange[](count);
        PriceRange[] memory prices = new PriceRange[](count);

        // use spot weights and initialPrices, collapsing high/low weight range
        count = 0;
        for (uint256 i; i < len; i++) {
            RebalanceDetails storage rebalanceDetails = rebalance.details[basketTokens[i]];

            if (rebalanceDetails.inRebalance) {
                tokens[count] = basketTokens[i];
                weights[count] = WeightRange({
                    low: rebalanceDetails.weights.spot,
                    spot: rebalanceDetails.weights.spot,
                    high: rebalanceDetails.weights.spot
                });
                prices[count] = rebalanceDetails.initialPrices;
                count++;
            }
        }

        // use spot limits, collapse high/low range
        RebalanceLimits memory limits = RebalanceLimits({
            low: rebalance.limits.spot,
            spot: rebalance.limits.spot,
            high: rebalance.limits.spot
        });

        // open an auction on spot limits, spot weights, and initial prices
        auctionId = _openAuction(rebalanceNonce, tokens, weights, prices, limits, RESTRICTED_AUCTION_BUFFER);
    }

    /// Get auction bid parameters for an ongoing auction in the current block, for some token pair
    /// @dev Result may be unreliable mid-swap during trusted fill execution, check stateChangeActive()
    /// @param sellToken The token to sell
    /// @param buyToken The token to buy
    /// @param maxSellAmount {sellTok} The max amount of sell tokens the bidder is willing to buy
    /// @return sellAmount {sellTok} The amount of sell token on sale in the auction at a given timestamp
    /// @return bidAmount {buyTok} The amount of buy tokens required to bid for the full sell amount
    /// @return price D27{buyTok/sellTok} The price at the given timestamp as an 27-decimal fixed point
    function getBid(
        uint256 auctionId,
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 maxSellAmount
    ) external view returns (uint256 sellAmount, uint256 bidAmount, uint256 price) {
        return _getBid(auctions[auctionId], sellToken, buyToken, 0, maxSellAmount, type(uint256).max);
    }

    /// Bid in an ongoing auction
    ///   If withCallback is true, caller must adhere to IBidderCallee interface and receives a callback
    ///   If withCallback is false, caller must have provided an allowance in advance
    /// @dev Callable by anyone
    /// @param sellAmount {sellTok} Sell token, the token the bidder receives
    /// @param maxBuyAmount {buyTok} Max buy token, the token the bidder provides
    /// @param withCallback If true, caller must adhere to IBidderCallee interface and transfers tokens via callback
    /// @param data Arbitrary data to pass to the callback
    /// @return boughtAmt {buyTok} The amount the bidder pays
    function bid(
        uint256 auctionId,
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 sellAmount,
        uint256 maxBuyAmount,
        bool withCallback,
        bytes calldata data
    ) external nonReentrant notDeprecated sync returns (uint256 boughtAmt) {
        require(rebalance.bidsEnabled, Folio__PermissionlessBidsDisabled());
        Auction storage auction = auctions[auctionId];

        // checks auction is ongoing and that boughtAmt is below maxBuyAmount
        (, boughtAmt, ) = _getBid(auction, sellToken, buyToken, sellAmount, sellAmount, maxBuyAmount);

        // bid via approval or callback
        if (RebalancingLib.bid(auction, auctionId, sellToken, buyToken, sellAmount, boughtAmt, withCallback, data)) {
            _removeFromBasket(address(sellToken));
        }
    }

    /// As an alternative to bidding directly, an in-block async swap can be opened without removing Folio's access
    function createTrustedFill(
        uint256 auctionId,
        IERC20 sellToken,
        IERC20 buyToken,
        address targetFiller,
        bytes32 deploymentSalt
    ) external nonReentrant notDeprecated sync returns (IBaseTrustedFiller filler) {
        require(
            address(trustedFillerRegistry) != address(0) && trustedFillerEnabled,
            Folio__TrustedFillerRegistryNotEnabled()
        );

        // checks auction is ongoing
        (uint256 sellAmount, uint256 buyAmount, ) = _getBid(
            auctions[auctionId],
            sellToken,
            buyToken,
            0,
            type(uint256).max,
            type(uint256).max
        );
        require(buyAmount != 0, Folio__InsufficientBuyAvailable());

        // Create Trusted Filler
        filler = trustedFillerRegistry.createTrustedFiller(msg.sender, targetFiller, deploymentSalt);
        SafeERC20.forceApprove(sellToken, address(filler), sellAmount);

        filler.initialize(address(this), sellToken, buyToken, sellAmount, buyAmount);
        activeTrustedFill = filler;

        emit AuctionTrustedFillCreated(auctionId, address(filler));
    }

    /// Close an auction
    /// A auction can be closed from anywhere in its lifecycle
    /// If you close an auction before startTime, it would break the invariant that endTime > startTime.
    /// @dev Callable by ADMIN or REBALANCE_MANAGER or AUCTION_LAUNCHER
    function closeAuction(uint256 auctionId) external nonReentrant {
        _checkPrivileged();

        if (auctions[auctionId].endTime < block.timestamp) {
            return;
        }

        // do not revert, to prevent griefing
        auctions[auctionId].endTime = block.timestamp - 1; // inclusive

        emit AuctionClosed(auctionId);
    }

    /// End the current rebalance, WITHOUT impacting any ongoing auction
    /// @dev Callable by ADMIN or REBALANCE_MANAGER or AUCTION_LAUNCHER
    function endRebalance() external nonReentrant {
        _checkPrivileged();

        emit RebalanceEnded(rebalance.nonce);

        // do not revert, to prevent griefing
        rebalance.availableUntil = block.timestamp; // exclusive
    }

    // ==== Internal ====

    function _checkPrivileged() internal view {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                hasRole(REBALANCE_MANAGER, msg.sender) ||
                hasRole(AUCTION_LAUNCHER, msg.sender),
            Folio__Unauthorized()
        );
    }

    /// @param shares {share}
    /// @return _assets
    /// @return _amounts {tok}
    function _toAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view returns (address[] memory _assets, uint256[] memory _amounts) {
        uint256 _totalSupply = totalSupply();

        (_assets, _amounts) = _totalAssets();

        uint256 assetLen = _assets.length;
        for (uint256 i; i < assetLen; i++) {
            // {tok} = {share} * {tok} / {share}
            _amounts[i] = Math.mulDiv(shares, _amounts[i], _totalSupply, rounding);
        }
    }

    /// @return _assets
    /// @return _amounts {tok}
    function _totalAssets() internal view returns (address[] memory _assets, uint256[] memory _amounts) {
        _assets = basket.values();

        uint256 assetLength = _assets.length;
        _amounts = new uint256[](assetLength);
        for (uint256 i; i < assetLength; i++) {
            _amounts[i] = _balanceOfToken(IERC20(_assets[i]));
        }
    }

    /// @return amount The known balances of a token, including trusted fills
    function _balanceOfToken(IERC20 token) internal view returns (uint256 amount) {
        amount = token.balanceOf(address(this));

        if (
            address(activeTrustedFill) != address(0) &&
            (activeTrustedFill.sellToken() == token || activeTrustedFill.buyToken() == token)
        ) {
            amount += token.balanceOf(address(activeTrustedFill));
        }
    }

    /// Open an auction
    /// @param rebalanceNonce The nonce of the rebalance being targeted
    /// @param tokens The tokens from the rebalance to include in the auction
    /// @param limits D18{BU/share} The BU limits for the auction
    /// @param auctionBuffer {s} The amount of extra buffer time to pad starting and ending rebalances/auctions
    /// @return auctionId The newly created auctionId
    function _openAuction(
        uint256 rebalanceNonce,
        address[] memory tokens,
        WeightRange[] memory weights,
        PriceRange[] memory prices,
        RebalanceLimits memory limits,
        uint256 auctionBuffer
    ) internal returns (uint256 auctionId) {
        // enforce rebalance ongoing
        require(
            rebalance.nonce == rebalanceNonce &&
                block.timestamp >= rebalance.startedAt + auctionBuffer &&
                block.timestamp < rebalance.availableUntil,
            Folio__NotRebalancing()
        );

        auctionId = nextAuctionId != 0 ? nextAuctionId : auctions_DEPRECATED.length;
        nextAuctionId = auctionId + 1;

        // close any previous auction
        if (auctionId != 0) {
            Auction storage lastAuction = auctions[auctionId - 1];

            // if auction collision
            if (
                lastAuction.rebalanceNonce == rebalanceNonce && lastAuction.endTime + auctionBuffer >= block.timestamp
            ) {
                require(auctionBuffer == 0, Folio__AuctionCannotBeOpenedWithoutRestriction());

                // close ongoing auction
                lastAuction.endTime = block.timestamp - 1;
                emit AuctionClosed(auctionId - 1);
            }
        }

        RebalancingLib.openAuction(rebalance, auctions, auctionId, tokens, weights, prices, limits, auctionLength);
    }

    /// Get auction bid parameters for a token pair at the current timestamp, up to a maximum sell amount
    /// @param sellToken The token to sell
    /// @param buyToken The token to buy
    /// @param maxSellAmount {sellTok} The max amount of sell tokens the bidder is willing to buy
    /// @return sellAmount {sellTok} The amount of sell token on sale in the auction at the given timestamp
    /// @return bidAmount {buyTok} The amount of buy tokens required to bid for the full sell amount
    /// @return price D27{buyTok/sellTok} The price at the given timestamp as an 27-decimal fixed point
    function _getBid(
        Auction storage auction,
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 minSellAmount,
        uint256 maxSellAmount,
        uint256 maxBuyAmount
    ) internal view returns (uint256 sellAmount, uint256 bidAmount, uint256 price) {
        RebalancingLib.GetBidParams memory params = RebalancingLib.GetBidParams({
            totalSupply: totalSupply(),
            sellBal: _balanceOfToken(sellToken),
            buyBal: _balanceOfToken(buyToken),
            minSellAmount: minSellAmount,
            maxSellAmount: maxSellAmount,
            maxBuyAmount: maxBuyAmount
        });

        // checks auction is ongoing and that sellAmount is below maxSellAmount
        (sellAmount, bidAmount, price) = RebalancingLib.getBid(rebalance, auction, sellToken, buyToken, params);
    }

    /// @return _daoPendingFeeShares {share}
    /// @return _feeRecipientsPendingFeeShares {share}
    function _getPendingFeeShares()
        internal
        view
        returns (uint256 _daoPendingFeeShares, uint256 _feeRecipientsPendingFeeShares, uint256 _accountedUntil)
    {
        // {s} Always in full days
        _accountedUntil = (block.timestamp / ONE_DAY) * ONE_DAY;
        uint256 elapsed = _accountedUntil > lastPoke ? _accountedUntil - lastPoke : 0;

        if (elapsed == 0) {
            return (daoPendingFeeShares, feeRecipientsPendingFeeShares, lastPoke);
        }

        (_daoPendingFeeShares, _feeRecipientsPendingFeeShares) = FolioLib.computeFeeShares(
            FolioLib.FeeSharesParams({
                currentDaoPending: daoPendingFeeShares,
                currentFeeRecipientsPending: feeRecipientsPendingFeeShares,
                tvlFee: tvlFee,
                folioFeeForSelf: folioFeeForSelf,
                supply: super.totalSupply() + daoPendingFeeShares + feeRecipientsPendingFeeShares,
                elapsed: elapsed
            }),
            daoFeeRegistry
        );
    }

    /// Set TVL fee by annual percentage. Different from how it is stored!
    /// @param _newFeeAnnually D18{1}
    function _setTVLFee(uint256 _newFeeAnnually) internal {
        tvlFee = FolioLib.setTVLFee(_newFeeAnnually);
    }

    /// Set mint fee
    /// @param _newFee D18{1}
    function _setMintFee(uint256 _newFee) internal {
        require(_newFee <= MAX_MINT_FEE, Folio__MintFeeTooHigh());

        mintFee = _newFee;
        emit MintFeeSet(_newFee);
    }

    /// Set folio fee — fraction of fee-recipient shares to burn
    /// @param _newFee D18{1}
    function _setFolioSelfFee(uint256 _newFee) internal {
        require(_newFee <= MAX_FOLIO_FEE, Folio__FolioFeeTooHigh());

        folioFeeForSelf = _newFee;
        emit FolioFeeSet(_newFee);
    }

    /// @param _newLength {s}
    function _setAuctionLength(uint256 _newLength) internal {
        require(_newLength >= MIN_AUCTION_LENGTH && _newLength <= MAX_AUCTION_LENGTH, Folio__InvalidAuctionLength());

        auctionLength = _newLength;
        emit AuctionLengthSet(auctionLength);
    }

    function _setMandate(string calldata _newMandate) internal {
        mandate = _newMandate;
        emit MandateSet(_newMandate);
    }

    /// @param _newName New token name
    function _setName(string calldata _newName) internal {
        ERC20Storage storage $;
        assembly {
            $.slot := ERC20_STORAGE_LOCATION
        }

        $._name = _newName;
        emit NameSet(_newName);
    }

    /// @dev After: daoPendingFeeShares and feeRecipientsPendingFeeShares are up-to-date
    function _poke() internal {
        _closeTrustedFill();

        (
            uint256 _daoPendingFeeShares,
            uint256 _feeRecipientsPendingFeeShares,
            uint256 _accountedUntil
        ) = _getPendingFeeShares();

        if (_accountedUntil > lastPoke) {
            daoPendingFeeShares = _daoPendingFeeShares;
            feeRecipientsPendingFeeShares = _feeRecipientsPendingFeeShares;
            lastPoke = _accountedUntil;
        }
    }

    function _addToBasket(address token) internal returns (bool) {
        require(token != address(0) && token != address(this), Folio__InvalidAsset());
        emit BasketTokenAdded(token);

        return basket.add(token);
    }

    function _removeFromBasket(address token) internal returns (bool) {
        emit BasketTokenRemoved(token);

        delete rebalance.details[token];

        return basket.remove(token);
    }

    function _setTrustedFillerRegistry(address _newFillerRegistry, bool _enabled) internal {
        if (address(trustedFillerRegistry) != _newFillerRegistry) {
            require(address(trustedFillerRegistry) == address(0), Folio__TrustedFillerRegistryAlreadySet());

            trustedFillerRegistry = ITrustedFillerRegistry(_newFillerRegistry);
        }

        if (trustedFillerEnabled != _enabled) {
            trustedFillerEnabled = _enabled;
        }

        emit TrustedFillerRegistrySet(address(trustedFillerRegistry), trustedFillerEnabled);
    }

    function _setRebalanceControl(RebalanceControl calldata _rebalanceControl) internal {
        rebalanceControl = _rebalanceControl;
        emit RebalanceControlSet(_rebalanceControl);
    }

    function _setBidsEnabled(bool _bidsEnabled) internal {
        bidsEnabled = _bidsEnabled;
        emit BidsEnabledSet(_bidsEnabled);
    }

    function _setTradeAllowlistEnabled(bool _enabled) internal {
        tradeAllowlistEnabled = _enabled;
        emit TradeAllowlistEnabled(_enabled);
    }

    function _setDaoFeeRegistry(address _newDaoFeeRegistry) internal {
        require(_newDaoFeeRegistry != address(0), Folio__InvalidRegistry());

        daoFeeRegistry = IFolioDAOFeeRegistry(_newDaoFeeRegistry);
    }

    /// Claim all token balances from outstanding trusted fill
    function _closeTrustedFill() internal {
        if (address(activeTrustedFill) != address(0)) {
            RebalancingLib.closeTrustedFill(auctions[nextAuctionId - 1], activeTrustedFill);
            delete activeTrustedFill;
        }
    }

    function _update(address from, address to, uint256 value) internal override {
        // prevent accidental donations
        require(to != address(this), Folio__InvalidTransferToSelf());
        // balances acquired prior to 4.0.0 may still reside at the contract

        super._update(from, to, value);
    }
}
