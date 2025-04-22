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

import { AuctionLib } from "@utils/AuctionLib.sol";
import { D18, D27, MAX_TVL_FEE, MAX_MINT_FEE, MIN_MINT_FEE, MIN_AUCTION_LENGTH, MAX_AUCTION_LENGTH, MAX_FEE_RECIPIENTS, MAX_LIMIT, MAX_TOKEN_PRICE, MAX_TOKEN_PRICE_RANGE, MAX_TTL, RESTRICTED_AUCTION_BUFFER, ONE_OVER_YEAR, ONE_DAY } from "@utils/Constants.sol";
import { MathLib } from "@utils/MathLib.sol";
import { Versioned } from "@utils/Versioned.sol";

import { IFolioDAOFeeRegistry } from "@interfaces/IFolioDAOFeeRegistry.sol";
import { IFolio } from "@interfaces/IFolio.sol";

/**
 * @title Folio
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Folio is a backed ERC20 token with permissionless minting/redemption and a rebalancing mechanism.
 *
 * A Folio is backed by a flexible number of ERC20 tokens of any denomination/price (within assumed ranges, see README)
 * All tokens tracked by the Folio are required to mint/redeem. This forms the basket.
 *
 * There are 3 main roles:
 *   1. DEFAULT_ADMIN_ROLE: can set erc20 assets, fees, auction length, close auctions/rebalances, and deprecateFolio
 *   2. REBALANCE_MANAGER: can start/end rebalances
 *   3. AUCTION_LAUNCHER: can open auctions during an ongoing rebalance, and close auctions
 *
 * There is also an additional BRAND_MANAGER role that does not have any permissions. It is used off-chain.
 *
 * Rebalance lifecycle:
 *   startRebalance() -> openAuction() -> bid() -> [optional] closeAuction()
 *
 * After a new rebalance is started by the REBALANCE_MANAGER, there is a period of time where only the AUCTION_LAUNCHER
 * can open auctions. They can choose to act within the range of the REBALANCE_MANAGER's initial estimates. After this
 * period is over, anyone can open auctions until the rebalance expires.
 *
 * An auction for a given token pair can run any number of times. However it requires the sell token to be in surplus
 * and the buy token in deficit.
 *
 * Targets for the rebalance are called "limits" and defined in basket ratios: ratios of token to Folio shares, D27{tok/share}
 *
 * Fees:
 *   - TVL fee: fee per unit time. Max 10% annually. Causes supply inflation over time, discretely once a day.
 *   - Mint fee: fee on mint. Max 5%. Does not cause supply inflation.
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

    IFolioDAOFeeRegistry public daoFeeRegistry;

    /**
     * Roles
     */
    bytes32 public constant REBALANCE_MANAGER = keccak256("REBALANCE_MANAGER"); // expected to be trading governance's timelock
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
    bool public isDeprecated; // {bool} if true, Folio goes into redemption-only mode

    modifier notDeprecated() {
        require(!isDeprecated, Folio__FolioDeprecated());
        _;
    }

    DeprecatedStruct[] private auctions_DEPRECATED;
    mapping(address token => uint256 timepoint) private sellEnds_DEPRECATED; // {s} timestamp of last possible second we could sell the token
    mapping(address token => uint256 timepoint) private buyEnds_DEPRECATED; // {s} timestamp of last possible second we could buy the token
    uint256 private auctionDelay_DEPRECATED; // {s} delay in the APPROVED state before an auction can be opened by anyone

    uint256 public auctionLength; // {s} length of an auction

    // === 2.0.0 ===
    mapping(uint256 auctionId => DeprecatedStruct details) private auctionDetails_DEPRECATED;
    mapping(address token => uint256 amount) private dustAmount_DEPRECATED;

    // === 3.0.0 ===
    ITrustedFillerRegistry public trustedFillerRegistry;
    bool public trustedFillerEnabled;
    IBaseTrustedFiller private activeTrustedFill;

    /**
     * Rebalancing
     *   REBALANCE_MANAGER
     *   - There can only be 1 rebalance live at a time
     *   - There can be an auction for each unique token pair in the basket
     *   - A token can be ONLY sold or ONLY bought depending on whether it is in surplus or deficit
     *   - Auctions are restricted to the AUCTION_LAUNCHER until rebalance.restrictedUntil
     *   - Auctions cannot be launched after availableUntil, though their end time may extend past it
     *   - The AUCTION_LAUNCHER acts within the bounds set by the REBALANCE_MANAGER, adding precision to limits/prices
     *   - If the AUCTION_LAUNCHER is not active, the original spot estimates from the REBALANCE_MANAGER are used
     *   - At anytime the rebalance can be stopped or a new one can be started (closing live auctions)
     *   - The AUCTION_LAUNCHER is limited in the damage they can do and can always be removed if griefing
     */
    Rebalance public rebalance;

    /**
     * Auctions
     *   Openable by AUCTION_LAUNCHER -> Openable by anyone (optional) -> Running -> Closed
     *   - There can only be one live auction per token pair
     *   - Multiple bids can be executed against the same auction
     *   - All auctions are dutch auctions with an exponential decay curve, but startPrice can equal endPrice
     */
    mapping(uint256 id => Auction auction) public auctions;
    mapping(uint256 rebalanceNonce => mapping(bytes32 pair => uint256 endTime)) public auctionEnds;
    uint256 public nextAuctionId;

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
        address _creator,
        address _daoFeeRegistry,
        address _trustedFillerRegistry,
        bool _trustedFillerEnabled
    ) external initializer {
        __ERC20_init(_basicDetails.name, _basicDetails.symbol);
        __AccessControlEnumerable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _setFeeRecipients(_additionalDetails.feeRecipients);
        _setTVLFee(_additionalDetails.tvlFee);
        _setMintFee(_additionalDetails.mintFee);
        _setAuctionLength(_additionalDetails.auctionLength);
        _setMandate(_additionalDetails.mandate);
        _setTrustedFillerRegistry(_trustedFillerRegistry, _trustedFillerEnabled);

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

    /// Check if the Folio state can be relied upon to be complete
    /// @dev Safety check for consuming protocols to check for synchronous and asynchronous state changes
    /// @dev Consuming protocols SHOULD call this function and ensure it returns (false, false) before
    ///      strongly relying on the Folio state.
    function stateChangeActive() external view returns (bool syncStateChangeActive, bool asyncStateChangeActive) {
        syncStateChangeActive = _reentrancyGuardEntered();
        asyncStateChangeActive = address(activeTrustedFill) != address(0) && activeTrustedFill.swapActive();
    }

    // ==== Governance ====

    /// Escape hatch function to be used when tokens get acquired not through an auction but
    /// through any other means and should become part of the Folio without being sold.
    /// @dev Does not require a token balance
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
                (rebalance.details[address(token)].limits.spot == 0 && IERC20(token).balanceOf(address(this)) == 0),
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

    /// @dev Non-reentrant via distributeFees()
    /// @dev Fee recipients must be unique and sorted by address, and sum to 1e18
    /// @dev Warning: An empty fee recipients table will result in all fees being sent to DAO
    function setFeeRecipients(FeeRecipient[] memory _newRecipients) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setFeeRecipients(_newRecipients);
    }

    /// @param _newLength {s} Length of an auction
    function setAuctionLength(uint256 _newLength) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAuctionLength(_newLength);
    }

    /// @param _newMandate New mandate, a schelling point to guide governance
    function setMandate(string calldata _newMandate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMandate(_newMandate);
    }

    /// @dev _newFillerRegistry must be the already set registry if already set. This is to ensure
    ///      correctness and in order to be explicit what registry is being enabled/disabled.
    function setTrustedFillerRegistry(address _newFillerRegistry, bool _enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTrustedFillerRegistry(_newFillerRegistry, _enabled);
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

    /// @return _assets
    /// @return _amounts {tok}
    function totalAssets() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        return _totalAssets();
    }

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

        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator, uint256 daoFeeFloor) = daoFeeRegistry.getFeeDetails(
            address(this)
        );

        // ensure DAO fee floor is at least 3 bps (set just above daily MAX_TVL_FEE)
        daoFeeFloor = Math.max(daoFeeFloor, MIN_MINT_FEE);

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

    /// Get the currently ongoing rebalance
    /// @dev The other rebalance variables are part of the autogenerated `rebalance()` getter
    /// @dev Nonzero return values do not imply a rebalance is ongoing; check `rebalance.availableUntil`
    function getRebalance()
        external
        view
        returns (
            address[] memory tokens,
            BasketRange[] memory limits,
            Prices[] memory prices,
            bool[] memory inRebalance
        )
    {
        tokens = basket.values();
        uint256 len = tokens.length;
        limits = new BasketRange[](len);
        prices = new Prices[](len);
        inRebalance = new bool[](len);

        for (uint256 i; i < len; i++) {
            RebalanceDetails storage details = rebalance.details[tokens[i]];
            limits[i] = details.limits;
            prices[i] = details.prices;
            inRebalance[i] = details.inRebalance;
        }
    }

    /// Set basket and start rebalancing towards it, ending currently running auctions
    /// @dev If caller omits old tokens they will be kept in the basket for mint/redeem but skipped in the rebalance
    /// @dev Note that limits will be _slightly_ stale after the fee supply inflation on a 24h boundary
    /// @param newTokens Tokens to add to the basket, MUST be unique
    /// @param newLimits D27{tok/share} New rebalance limits
    /// @param newPrices D27{UoA/tok} New prices for each asset in terms of the Folio
    ///                  Can pass 0 for ALL token prices to defer to AUCTION_LAUNCHER (cannot pick and choose)
    function startRebalance(
        address[] calldata newTokens,
        BasketRange[] calldata newLimits,
        Prices[] calldata newPrices,
        uint256 auctionLauncherWindow,
        uint256 ttl
    ) external onlyRole(REBALANCE_MANAGER) nonReentrant notDeprecated sync {
        require(ttl >= auctionLauncherWindow && ttl <= MAX_TTL, Folio__InvalidTTL());

        // keep old tokens in the basket for mint/redeem, but remove from rebalance
        address[] memory oldTokens = basket.values();
        uint256 len = oldTokens.length;
        for (uint256 i; i < len; i++) {
            delete rebalance.details[oldTokens[i]];
        }

        len = newTokens.length;
        require(len != 0 && len == newLimits.length && len == newPrices.length, Folio__InvalidArrayLengths());

        // enforce that if one price is 0, all prices are 0
        bool deferPrices = newPrices[0].low == 0;

        // set new basket
        for (uint256 i; i < len; i++) {
            address token = newTokens[i];

            require(!rebalance.details[token].inRebalance, Folio__DuplicateAsset());

            require(
                newLimits[i].low <= newLimits[i].spot &&
                    newLimits[i].spot <= newLimits[i].high &&
                    newLimits[i].high <= MAX_LIMIT,
                Folio__InvalidLimits()
            );

            require(newLimits[i].spot != 0 || newLimits[i].high == 0, Folio__InvalidLimits());

            require(
                deferPrices == (newPrices[i].low == 0) && deferPrices == (newPrices[i].high == 0),
                Folio__InvalidPrices()
            );

            if (!deferPrices) {
                require(
                    newPrices[i].low <= newPrices[i].high &&
                        newPrices[i].high <= MAX_TOKEN_PRICE &&
                        newPrices[i].high / newPrices[i].low <= MAX_TOKEN_PRICE_RANGE,
                    Folio__InvalidPrices()
                );
            }

            _addToBasket(token);
            rebalance.details[token] = RebalanceDetails({
                inRebalance: true,
                limits: newLimits[i],
                prices: newPrices[i]
            });
        }

        rebalance.nonce++;
        rebalance.startedAt = block.timestamp;
        rebalance.restrictedUntil = block.timestamp + auctionLauncherWindow;
        rebalance.availableUntil = block.timestamp + ttl;

        emit RebalanceStarted(
            rebalance.nonce,
            newTokens,
            newLimits,
            newPrices,
            block.timestamp + auctionLauncherWindow,
            block.timestamp + ttl
        );
    }

    /// Open an auction between two tokens as the AUCTION_LAUNCHER, with specific limits and prices
    /// @param sellLimit D27{sellTok/share} min ratio of sell token to shares allowed, inclusive, 1e54 max
    /// @param buyLimit D27{buyTok/share} max balance-ratio to shares allowed, exclusive, 1e54 max
    /// @param startPrice D27{buyTok/sellTok} (0, 1e54]
    /// @param endPrice D27{buyTok/sellTok} (0, 1e54]
    /// @return auctionId The newly created auctionId
    function openAuction(
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 sellLimit,
        uint256 buyLimit,
        uint256 startPrice,
        uint256 endPrice
    ) external onlyRole(AUCTION_LAUNCHER) nonReentrant notDeprecated sync returns (uint256 auctionId) {
        // auction launcher can:
        //   - select a sell limit within the approved basket weight range
        //   - select a buy limit within the approved basket weight range
        //   - raise starting price by up to 100x
        //   - raise ending price arbitrarily (can cause auction not to clear, same end result as closing auction)

        RebalanceDetails storage sellDetails = rebalance.details[address(sellToken)];
        RebalanceDetails storage buyDetails = rebalance.details[address(buyToken)];

        // startRebalance invariant: if any of the tokens have a 0 price, they must all have a 0 price
        if (sellDetails.prices.high != 0) {
            // D27{buyTok/sellTok} = D27 * D27{UoA/sellTok} / D27{UoA/buyTok}
            uint256 oldStartPrice = (D27 * sellDetails.prices.high + buyDetails.prices.low - 1) / buyDetails.prices.low;
            uint256 oldEndPrice = (D27 * sellDetails.prices.low + buyDetails.prices.high - 1) / buyDetails.prices.high;

            // allow up to 100x price increase
            require(
                startPrice >= oldStartPrice && startPrice <= 100 * oldStartPrice && endPrice >= oldEndPrice,
                Folio__InvalidPrices()
            );
        }

        // for upgraded Folios, pick up on the next auction index from the old array
        nextAuctionId = nextAuctionId != 0 ? nextAuctionId : auctions_DEPRECATED.length;
        auctionId = nextAuctionId++;

        AuctionLib.AuctionArgs memory args = AuctionLib.AuctionArgs({
            auctionId: auctionId,
            sellToken: sellToken,
            buyToken: buyToken,
            sellLimit: sellLimit,
            buyLimit: buyLimit,
            startPrice: startPrice,
            endPrice: endPrice,
            auctionBuffer: 0
        });

        // many more checks, including confirming sellToken is in surplus and buyToken is in deficit
        AuctionLib.openAuction(rebalance, auctions, auctionEnds, totalSupply(), auctionLength, args);
    }

    /// Open an auction without restrictions
    /// @dev Callable only after the auction launcher window passes
    /// @return auctionId The newly created auctionId
    function openAuctionUnrestricted(
        IERC20 sellToken,
        IERC20 buyToken
    ) external nonReentrant notDeprecated sync returns (uint256 auctionId) {
        require(block.timestamp >= rebalance.restrictedUntil, Folio__AuctionCannotBeOpenedWithoutRestriction());

        // open an auction on spot limits + full price range

        RebalanceDetails storage sellDetails = rebalance.details[address(sellToken)];
        RebalanceDetails storage buyDetails = rebalance.details[address(buyToken)];

        // startRebalance invariant: if any of the tokens have a 0 price, they must all have a 0 price
        require(buyDetails.prices.low != 0, Folio__AuctionCannotBeOpenedWithoutRestriction());

        // D27{buyTok/sellTok} = D27 * D27{UoA/sellTok} / D27{UoA/buyTok}
        uint256 startPrice = (D27 * sellDetails.prices.high + buyDetails.prices.low - 1) / buyDetails.prices.low;
        uint256 endPrice = (D27 * sellDetails.prices.low + buyDetails.prices.high - 1) / buyDetails.prices.high;

        // for upgraded Folios, pick up on the next auction index from the old array
        nextAuctionId = nextAuctionId != 0 ? nextAuctionId : auctions_DEPRECATED.length;
        auctionId = nextAuctionId++;

        AuctionLib.AuctionArgs memory args = AuctionLib.AuctionArgs({
            auctionId: auctionId,
            sellToken: sellToken,
            buyToken: buyToken,
            sellLimit: sellDetails.limits.spot,
            buyLimit: buyDetails.limits.spot,
            startPrice: startPrice,
            endPrice: endPrice,
            auctionBuffer: RESTRICTED_AUCTION_BUFFER
        });

        // many more checks, including confirming sellToken is in surplus and buyToken is in deficit
        AuctionLib.openAuction(rebalance, auctions, auctionEnds, totalSupply(), auctionLength, args);
    }

    /// Get auction bid parameters at the current timestamp, up to a maximum sell amount
    /// @param timestamp {s} The timestamp to get the bid parameters for, or 0 to use the current timestamp
    /// @param maxSellAmount {sellTok} The max amount of sell tokens the bidder can offer the protocol
    /// @return sellAmount {sellTok} The amount of sell token on sale in the auction at a given timestamp
    /// @return bidAmount {buyTok} The amount of buy tokens required to bid for the full sell amount
    /// @return price D27{buyTok/sellTok} The price at the given timestamp as an 27-decimal fixed point
    function getBid(
        uint256 auctionId,
        uint256 timestamp,
        uint256 maxSellAmount
    ) external view returns (uint256 sellAmount, uint256 bidAmount, uint256 price) {
        Auction storage auction = auctions[auctionId];

        require(auction.rebalanceNonce == rebalance.nonce, Folio__AuctionNotOngoing());

        // checks auction is ongoing and that sellAmount is below maxSellAmount
        (sellAmount, bidAmount, price) = AuctionLib.getBid(
            auction,
            totalSupply(),
            timestamp == 0 ? block.timestamp : timestamp,
            _balanceOfToken(auction.sellToken),
            _balanceOfToken(auction.buyToken),
            0,
            maxSellAmount,
            type(uint256).max
        );
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
    ) external nonReentrant notDeprecated sync returns (uint256 boughtAmt) {
        Auction storage auction = auctions[auctionId];

        require(auction.rebalanceNonce == rebalance.nonce, Folio__AuctionNotOngoing());

        uint256 _totalSupply = totalSupply();

        // checks auction is ongoing and that sellAmount is below maxSellAmount
        (, boughtAmt, ) = AuctionLib.getBid(
            auction,
            _totalSupply,
            block.timestamp,
            auction.sellToken.balanceOf(address(this)),
            auction.buyToken.balanceOf(address(this)),
            sellAmount,
            sellAmount,
            maxBuyAmount
        );

        // bid via approval or callback
        if (
            AuctionLib.bid(
                auction,
                auctionEnds[auction.rebalanceNonce],
                _totalSupply,
                sellAmount,
                boughtAmt,
                withCallback,
                data
            )
        ) {
            _removeFromBasket(address(auction.sellToken));
        }

        emit AuctionBid(auctionId, sellAmount, boughtAmt);
    }

    /// As an alternative to bidding directly, an in-block async swap can be opened without removing Folio's access
    function createTrustedFill(
        uint256 auctionId,
        address targetFiller,
        bytes32 deploymentSalt
    ) external nonReentrant notDeprecated sync returns (IBaseTrustedFiller filler) {
        Auction storage auction = auctions[auctionId];

        require(auction.rebalanceNonce == rebalance.nonce, Folio__AuctionNotOngoing());
        require(
            address(trustedFillerRegistry) != address(0) && trustedFillerEnabled,
            Folio__TrustedFillerRegistryNotEnabled()
        );

        // checks auction is ongoing and that sellAmount is below maxSellAmount
        (uint256 sellAmount, uint256 buyAmount, ) = AuctionLib.getBid(
            auction,
            totalSupply(),
            block.timestamp,
            auction.sellToken.balanceOf(address(this)),
            auction.buyToken.balanceOf(address(this)),
            0,
            type(uint256).max,
            type(uint256).max
        );

        // Create Trusted Filler
        filler = trustedFillerRegistry.createTrustedFiller(msg.sender, targetFiller, deploymentSalt);
        SafeERC20.forceApprove(auction.sellToken, address(filler), sellAmount);

        filler.initialize(address(this), auction.sellToken, auction.buyToken, sellAmount, buyAmount);
        activeTrustedFill = filler;

        emit AuctionTrustedFillCreated(auctionId, address(filler));
    }

    /// Close an auction
    /// A auction can be closed from anywhere in its lifecycle
    /// @dev Callable by ADMIN or REBALANCE_MANAGER or AUCTION_LAUNCHER
    function closeAuction(uint256 auctionId) external nonReentrant {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                hasRole(REBALANCE_MANAGER, msg.sender) ||
                hasRole(AUCTION_LAUNCHER, msg.sender),
            Folio__Unauthorized()
        );
        Auction storage auction = auctions[auctionId];

        // do not revert, to prevent griefing
        auction.endTime = block.timestamp - 1;
        auctionEnds[auction.rebalanceNonce][AuctionLib.pairHash(auction.sellToken, auction.buyToken)] =
            block.timestamp -
            1;

        emit AuctionClosed(auctionId);
    }

    /// End the current rebalance, including all ongoing auctions
    /// @dev Callable by ADMIN or REBALANCE_MANAGER or AUCTION_LAUNCHER
    /// @dev Still have to wait out auctionEnds after
    function endRebalance() external nonReentrant {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                hasRole(REBALANCE_MANAGER, msg.sender) ||
                hasRole(AUCTION_LAUNCHER, msg.sender),
            Folio__Unauthorized()
        );

        emit RebalanceEnded(rebalance.nonce);

        // do not revert, to prevent griefing
        rebalance.nonce++; // advancing nonce clears auctionEnds
        rebalance.availableUntil = block.timestamp;
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

        _daoPendingFeeShares = daoPendingFeeShares;
        _feeRecipientsPendingFeeShares = feeRecipientsPendingFeeShares;

        // {share}
        uint256 supply = super.totalSupply() + _daoPendingFeeShares + _feeRecipientsPendingFeeShares;

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

    /// Claim all token balances from outstanding trusted fill
    function _closeTrustedFill() internal {
        if (address(activeTrustedFill) != address(0)) {
            activeTrustedFill.closeFiller();

            delete activeTrustedFill;
        }
    }

    function _update(address from, address to, uint256 value) internal override {
        // prevent accidental donations
        require(to != address(this), Folio__InvalidTransferToSelf());

        super._update(from, to, value);
    }
}
