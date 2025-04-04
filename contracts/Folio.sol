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
import { D18, D27, MAX_TVL_FEE, MAX_MINT_FEE, MIN_AUCTION_LENGTH, MAX_AUCTION_LENGTH, MAX_AUCTION_DELAY, MAX_FEE_RECIPIENTS, MAX_PRICE_RANGE, MAX_RATE, MAX_TTL, RESTRICTED_AUCTION_BUFFER, ONE_OVER_YEAR } from "@utils/Constants.sol";
import { MathLib } from "@utils/MathLib.sol";
import { Versioned } from "@utils/Versioned.sol";

import { IBidderCallee } from "@interfaces/IBidderCallee.sol";
import { IFolioDAOFeeRegistry } from "@interfaces/IFolioDAOFeeRegistry.sol";
import { IFolio } from "@interfaces/IFolio.sol";

/**
 * @title Folio
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Folio is a backed ERC20 token with permissionless minting/redemption and rebalancing via dutch auction
 *
 * A Folio is backed by a flexible number of ERC20 tokens of any denomination/price (within assumed ranges, see README)
 * All tokens tracked by the Folio are required to mint/redeem. This forms the basket.
 *
 * There are 3 main roles:
 *   1. DEFAULT_ADMIN_ROLE: can set erc20 assets, fees, auction length, auction delay, close auctions, and deprecateFolio
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

    IFolioDAOFeeRegistry public daoFeeRegistry;

    /**
     * Roles
     */
    bytes32 public constant BASKET_MANAGER = keccak256("BASKET_MANAGER"); // expected to be trading governance's timelock
    bytes32 public constant AUCTION_LAUNCHER = keccak256("AUCTION_LAUNCHER"); // optional: EOA or multisig
    bytes32 public constant BRAND_MANAGER = keccak256("BRAND_MANAGER"); // optional: no permissions
    /// === DEPRECATED ===
    bytes32 public constant AUCTION_APPROVER = keccak256("AUCTION_APPROVER");

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

    DeprecatedStruct[] public auctions_DEPRECATED;
    mapping(address token => uint256 timepoint) public sellEnds_DEPRECATED; // {s} timestamp of last possible second we could sell the token
    mapping(address token => uint256 timepoint) public buyEnds_DEPRECATED; // {s} timestamp of last possible second we could buy the token
    uint256 public auctionDelay_DEPRECATED; // {s} delay in the APPROVED state before an auction can be opened by anyone

    uint256 public auctionLength; // {s} length of an auction

    // === 2.0.0 ===
    mapping(uint256 auctionId => DeprecatedStruct details) public auctionDetails_DEPRECATED;
    mapping(address token => uint256 amount) private dustAmount_DEPRECATED;

    // === 3.0.0 ===
    ITrustedFillerRegistry public trustedFillerRegistry;
    bool public trustedFillerEnabled;
    IBaseTrustedFiller private activeTrustedFill;

    // === 4.0.0 ===
    /**
     * Rebalancing
     *   - The rebalancing process runs until rebalance.availableUntil
     *   - Rebalancing cannot be called by anyone other than the BASKET_MANAGER until rebalance.restrictedUntil
     *   - Any number of auctions can be opened within the rebalancing period toward reaching the set limits
     *   - The AUCTION_LAUNCHER has the ability to progressively constrain limits before each auction
     *   - At anytime a new rebalance can be started to immediately end all ongoing auctions
     */
    Rebalance public rebalance;

    /**
     * Auctions
     *   Openable by AUCTION_LAUNCHER -> Openable by anyone (optional) -> Running -> Closed
     *   - During rebalancing, auctions are only available to AUCTION_LAUNCHER until rebalance.restrictedUntil
     *   - During rebalancing, auctions can be until rebalance.availableUntil
     *   - There can only be one live auction per token pair
     *   - Multiple bids can be executed against the same auction
     *   - All auctions are dutch auctions with an exponential decay curve, but startPrice can equal endPrice
     */
    mapping(uint256 id => Auction auction) public auctions;
    mapping(uint256 rebalanceNonce => mapping(bytes32 pair => uint256 endTime)) public auctionEnds;
    uint256 public nextAuctionId;

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

    /// @dev Reentrancy guard check for consuming protocols
    /// @dev Consuming protocols SHOULD call this function and ensure it returns false before
    ///      strongly relying on the Folio state
    function reentrancyGuardEntered() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    // ==== Governance ====

    /// @dev Enables permissonless removal of tokens for 0 balance tokens
    /// @dev Made permissionless in 3.0.0
    function removeFromBasket(IERC20 token) external nonReentrant {
        _closeTrustedFill();

        // always allow admin to remove from basket
        // allow permissionless removal if 0 weight AND 0 balance
        // known: can be griefed by token donation
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                (rebalance.limits[address(token)].spot == 0 && IERC20(token).balanceOf(address(this)) == 0),
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
    function deprecateFolio() external onlyRole(DEFAULT_ADMIN_ROLE) {
        isDeprecated = true;

        emit FolioDeprecated();
    }

    // ==== Share + Asset Accounting ====

    /// @dev Contains all pending fee shares
    function totalSupply() public view virtual override(ERC20Upgradeable) returns (uint256) {
        (uint256 _daoPendingFeeShares, uint256 _feeRecipientsPendingFeeShares) = _getPendingFeeShares();

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
    ) external nonReentrant notDeprecated returns (address[] memory _assets, uint256[] memory _amounts) {
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

    /// Get the currently ongoing rebalance
    /// @dev (nonce, restrictedUNtil, availableUntil) are auto-generated
    function getRebalance()
        external
        view
        returns (address[] memory tokens, BasketRange[] memory weights, Prices[] memory prices)
    {
        tokens = basket.values();
        uint256 len = tokens.length;
        weights = new BasketRange[](len);
        prices = new Prices[](len);

        for (uint256 i; i < len; i++) {
            weights[i] = rebalance.limits[tokens[i]];
            prices[i] = rebalance.prices[tokens[i]];
        }
    }

    /// Set basket and start rebalancing towards it, ending currently running auctions
    /// @dev Caller SHOULD try to not omit old tokens
    ///      Worst-case: keeps old tokens around for mint/redeem but excludes from rebalance
    /// @param newWeights D27{tok/share} New basket weights
    /// @param newPrices D27{tok/share} New prices for each asset in terms of the Folio (NOT weights)
    ///                  Can pass 0 to defer to AUCTION_LAUNCHER
    function startRebalance(
        address[] calldata newTokens,
        BasketRange[] calldata newWeights,
        Prices[] calldata newPrices,
        uint256 auctionLauncherWindow,
        uint256 ttl
    ) external onlyRole(BASKET_MANAGER) {
        require(ttl >= auctionLauncherWindow && ttl < MAX_TTL, Folio__InvalidTTL());

        // keep old tokens in the basket for mint/redeem, but remove from rebalance
        address[] memory oldTokens = basket.values();
        uint256 len = oldTokens.length;
        for (uint256 i; i < len; i++) {
            address token = oldTokens[i];

            delete rebalance.inRebalance[token];
            delete rebalance.limits[token];
            delete rebalance.prices[token];
        }

        len = newTokens.length;
        require(len == newWeights.length, Folio__InvalidArrayLengths());
        require(len == newPrices.length, Folio__InvalidArrayLengths());

        // set new basket
        for (uint i; i < len; i++) {
            address token = newTokens[i];

            require(token != address(0) && token != address(this), Folio__InvalidAsset());
            require(
                newWeights[i].low <= newWeights[i].spot &&
                    newWeights[i].spot <= newWeights[i].high &&
                    newWeights[i].high <= MAX_RATE,
                Folio__InvalidWeights()
            );
            require(newPrices[i].low <= newPrices[i].high && newPrices[i].high <= MAX_RATE, Folio__InvalidPrices());
            // prices are permitted to be zero at this stage to defer to AUCTION_LAUNCHER

            basket.add(token);
            rebalance.inRebalance[token] = true;
            rebalance.limits[token] = newWeights[i];
            rebalance.prices[token] = newPrices[i];
        }

        rebalance.restrictedUntil = block.timestamp + auctionLauncherWindow;
        rebalance.availableUntil = block.timestamp + ttl;
        rebalance.nonce++;

        emit RebalanceStarted(
            rebalance.nonce,
            newTokens,
            newWeights,
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
    ) external nonReentrant onlyRole(AUCTION_LAUNCHER) notDeprecated returns (uint256) {
        // auction launcher can:
        //   - select a sell limit within the approved basket weight range
        //   - select a buy limit within the approved basket weight range
        //   - raise starting price by up to 100x
        //   - raise ending price arbitrarily (can cause auction not to clear, same as closing auction)

        // check prices
        Prices storage sellPrices = rebalance.prices[address(sellToken)];
        Prices storage buyPrices = rebalance.prices[address(buyToken)];

        // D27{buyTok/sellTok} = D27 * D27{buyTok/share} / D27{sellTok/share}
        uint256 oldStartPrice = (D27 * buyPrices.low) / sellPrices.high;
        uint256 oldEndPrice = (D27 * buyPrices.high) / sellPrices.low;

        require(
            startPrice >= oldStartPrice &&
                endPrice >= oldEndPrice &&
                (oldStartPrice == 0 || startPrice <= 100 * oldStartPrice),
            Folio__InvalidPrices()
        );

        // check limits
        BasketRange storage sellWeights = rebalance.limits[address(sellToken)];
        BasketRange storage buyWeights = rebalance.limits[address(buyToken)];

        require(sellLimit >= sellWeights.low && sellLimit <= sellWeights.high, Folio__InvalidSellWeight());
        require(buyLimit >= buyWeights.low && buyLimit <= buyWeights.high, Folio__InvalidBuyWeight());

        // update basket weights for next time, incase it is via openAuctionUnrestricted
        sellWeights.spot = sellLimit;
        buyWeights.spot = buyLimit;

        // bring basket range up behind us to prevent double trading later
        sellWeights.high = sellLimit;
        buyWeights.low = buyLimit;

        // more checks, including confirming sellToken is in surplus and buyToken is in deficit
        return _openAuction(sellToken, buyToken, sellLimit, buyLimit, startPrice, endPrice, 0);
    }

    /// Open an auction between two tokens (without calling restriction)
    /// @return auctionId The newly created auctionId
    function openAuctionUnrestricted(
        IERC20 sellToken,
        IERC20 buyToken
    ) external nonReentrant notDeprecated returns (uint256) {
        // open an auction on spot limits + full price range

        Prices storage sellPrices = rebalance.prices[address(sellToken)];
        Prices storage buyPrices = rebalance.prices[address(buyToken)];

        // check prices
        // D27{buyTok/sellTok} = D27 * D27{buyTok/share} / D27{sellTok/share}
        uint256 startPrice = (D27 * buyPrices.low) / sellPrices.high;
        uint256 endPrice = (D27 * buyPrices.high) / sellPrices.low;
        uint256 sellLimit = rebalance.limits[address(sellToken)].spot;
        uint256 buyLimit = rebalance.limits[address(buyToken)].spot;

        return _openAuction(sellToken, buyToken, sellLimit, buyLimit, startPrice, endPrice, RESTRICTED_AUCTION_BUFFER);
    }

    /// Get auction bid parameters at the current timestamp, up to a maximum sell amount
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
    ) external nonReentrant notDeprecated returns (uint256 boughtAmt) {
        _closeTrustedFill();
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
    ) external nonReentrant notDeprecated returns (IBaseTrustedFiller filler) {
        _closeTrustedFill();
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

        _addToBasket(address(auction.buyToken));
        emit AuctionTrustedFillCreated(auctionId, address(filler));
    }

    /// Close an auction
    /// A auction can be closed from anywhere in its lifecycle, and cannot be restarted
    /// @dev Callable by ADMIN or BASKET_MANAGER or AUCTION_LAUNCHER
    function closeAuction(uint256 auctionId) external nonReentrant {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                hasRole(BASKET_MANAGER, msg.sender) ||
                hasRole(AUCTION_LAUNCHER, msg.sender),
            Folio__Unauthorized()
        );

        bytes32 pair = _pair(address(auctions[auctionId].sellToken), address(auctions[auctionId].buyToken));

        // do not revert, to prevent griefing
        auctions[auctionId].endTime = block.timestamp - 1;
        delete auctionEnds[rebalance.nonce][pair];
        emit AuctionClosed(auctionId);
    }

    /// End the current rebalance, including all ongoing auctions
    /// @dev Callable by ADMIN or BASKET_MANAGER or AUCTION_LAUNCHER
    /// @dev Still have to wait out auctionEnds after
    function endRebalance() external nonReentrant {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                hasRole(BASKET_MANAGER, msg.sender) ||
                hasRole(AUCTION_LAUNCHER, msg.sender),
            Folio__Unauthorized()
        );

        // do not revert, to prevent griefing
        rebalance.nonce++; // advancing nonce clears auctionEnds
        rebalance.availableUntil = block.timestamp;

        emit RebalanceEnded();
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

    /// @return pair The hash of the pair
    function _pair(address sellToken, address buyToken) internal pure returns (bytes32) {
        return keccak256(abi.encode(sellToken, buyToken));
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

        // {s}
        uint256 elapsed = block.timestamp - lastPoke;

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

    /// @return auctionId The newly created auctionId
    function _openAuction(
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 sellWeight,
        uint256 buyWeight,
        uint256 startPrice,
        uint256 endPrice,
        uint256 auctionBuffer
    ) internal returns (uint256 auctionId) {
        _closeTrustedFill();

        // confirm tokens are in basket
        require(
            basket.contains(address(sellToken)) && basket.contains(address(buyToken)),
            Folio__InvalidAuctionTokens()
        );

        // confirm tokens are in rebalance
        require(
            rebalance.inRebalance[address(sellToken)] && rebalance.inRebalance[address(buyToken)],
            Folio__NotRebalancing()
        );

        // confirm a rebalance ongoing
        require(block.timestamp < rebalance.availableUntil, Folio__NotRebalancing());

        // confirm no auction collision on token pair
        {
            bytes32 pair = _pair(address(sellToken), address(buyToken));
            require(block.timestamp > auctionEnds[rebalance.nonce][pair] + auctionBuffer, Folio__AuctionCollision());
            auctionEnds[rebalance.nonce][pair] = block.timestamp + auctionLength;
        }

        // confirm sellToken is in surplus and buyToken is in deficit
        {
            uint256 _totalSupply = totalSupply();

            // {sellTok} = D27{sellTok/share} * {share} / D27
            uint256 sellBalLimit = Math.mulDiv(sellWeight, _totalSupply, D27, Math.Rounding.Ceil);
            require(sellToken.balanceOf(address(this)) > sellBalLimit, Folio__InvalidSellWeight());

            // {buyTok} = D27{buyTok/share} * {share} / D27
            uint256 buyBalLimit = Math.mulDiv(buyWeight, _totalSupply, D27, Math.Rounding.Floor);
            require(buyToken.balanceOf(address(this)) < buyBalLimit, Folio__InvalidBuyWeight());
        }

        // for upgraded Folios, pick up on the next auction index from the old array
        nextAuctionId = nextAuctionId != 0 ? nextAuctionId : auctions_DEPRECATED.length;
        auctionId = nextAuctionId++;

        // ensure valid price range (startPrice == endPrice is valid)
        require(
            startPrice >= endPrice &&
                endPrice != 0 &&
                startPrice <= MAX_RATE &&
                startPrice / endPrice <= MAX_PRICE_RANGE,
            Folio__InvalidPrices()
        );

        Auction memory auction = Auction({
            rebalanceNonce: rebalance.nonce,
            sellToken: sellToken,
            buyToken: buyToken,
            sellLimit: sellWeight,
            buyLimit: buyWeight,
            startPrice: startPrice,
            endPrice: endPrice,
            startTime: block.timestamp,
            endTime: block.timestamp + auctionLength
        });
        auctions[auctionId] = auction;

        emit AuctionOpened(auctionId, auction);
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

        if (lastPoke == block.timestamp) {
            return;
        }

        (daoPendingFeeShares, feeRecipientsPendingFeeShares) = _getPendingFeeShares();
        lastPoke = block.timestamp;
    }

    function _addToBasket(address token) internal returns (bool) {
        require(token != address(0) && token != address(this), Folio__InvalidAsset());
        emit BasketTokenAdded(token);

        return basket.add(token);
    }

    function _removeFromBasket(address token) internal returns (bool) {
        emit BasketTokenRemoved(token);

        delete rebalance.limits[token];
        delete rebalance.prices[token];

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
