// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFolio {
    // === Events ===

    event AuctionOpened(
        uint256 indexed rebalanceNonce,
        uint256 indexed auctionId,
        address[] tokens,
        WeightRange[] weights,
        PriceRange[] prices,
        RebalanceLimits limits,
        uint256 startTime,
        uint256 endTime
    );
    event AuctionBid(
        uint256 indexed auctionId,
        address indexed sellToken,
        address indexed buyToken,
        uint256 sellAmount,
        uint256 buyAmount
    );
    event AuctionClosed(uint256 indexed auctionId);
    event AuctionTrustedFillCreated(uint256 indexed auctionId, address filler);

    event FolioFeePaid(address indexed recipient, uint256 amount);
    event ProtocolFeePaid(address indexed recipient, uint256 amount);

    event BasketTokenAdded(address indexed token);
    event BasketTokenRemoved(address indexed token);
    event TVLFeeSet(uint256 newFee, uint256 feeAnnually);
    event MintFeeSet(uint256 newFee);
    event FeeRecipientsSet(FeeRecipient[] recipients);
    event AuctionLengthSet(uint256 newAuctionLength);
    event MandateSet(string newMandate);
    event TrustedFillerRegistrySet(address trustedFillerRegistry, bool isEnabled);
    event FolioDeprecated();

    event RebalanceControlSet(RebalanceControl newControl);
    event RebalanceStarted(
        uint256 nonce,
        PriceControl priceControl,
        address[] tokens,
        WeightRange[] weights,
        PriceRange[] prices,
        RebalanceLimits limits,
        uint256 restrictedUntil,
        uint256 availableUntil
    );
    event RebalanceEnded(uint256 nonce);
    event BidsEnabledSet(bool bidsEnabled);
    event NameSet(string name);
    event SymbolSet(string symbol);
    // === Errors ===

    error Folio__FolioDeprecated();
    error Folio__Unauthorized();

    error Folio__EmptyAssets();
    error Folio__BasketModificationFailed();
    error Folio__BalanceNotRemovable();

    error Folio__FeeRecipientInvalidAddress();
    error Folio__FeeRecipientInvalidFeeShare();
    error Folio__BadFeeTotal();
    error Folio__TVLFeeTooHigh();
    error Folio__TVLFeeTooLow();
    error Folio__MintFeeTooHigh();
    error Folio__ZeroInitialShares();

    error Folio__InvalidAsset();
    error Folio__DuplicateAsset();
    error Folio__InvalidAssetAmount(address asset);

    error Folio__InvalidAuctionLength();
    error Folio__InvalidLimits();
    error Folio__InvalidWeights();
    error Folio__AuctionCannotBeOpenedWithoutRestriction();
    error Folio__AuctionNotOngoing();
    error Folio__InvalidPrices();
    error Folio__SlippageExceeded();
    error Folio__InsufficientSellAvailable();
    error Folio__InsufficientBuyAvailable();
    error Folio__InsufficientBid();
    error Folio__InsufficientSharesOut();
    error Folio__TooManyFeeRecipients();
    error Folio__InvalidArrayLengths();
    error Folio__InvalidTransferToSelf();

    error Folio__InvalidRegistry();
    error Folio__TrustedFillerRegistryNotEnabled();
    error Folio__TrustedFillerRegistryAlreadySet();
    error Folio__InvalidTTL();
    error Folio__NotRebalancing();
    error Folio__MixedAtomicSwaps();
    error Folio__PermissionlessBidsDisabled();

    // === Structures ===

    /// Price control AUCTION_LAUNCHER has on rebalancing
    enum PriceControl {
        NONE, // cannot change prices
        PARTIAL, // can set auction prices within bounds of initial prices
        ATOMIC_SWAP // PARTIAL + ability to set startPrice equal to endPrice
    }

    struct FolioBasicDetails {
        string name;
        string symbol;
        address[] assets;
        uint256[] amounts; // {tok}
        uint256 initialShares; // {share}
    }

    struct FolioAdditionalDetails {
        uint256 auctionLength; // {s}
        FeeRecipient[] feeRecipients;
        uint256 tvlFee; // D18{1/s}
        uint256 mintFee; // D18{1}
        string mandate;
    }

    struct FolioRegistryIndex {
        address daoFeeRegistry;
        address trustedFillerRegistry;
    }

    struct FolioFlags {
        bool trustedFillerEnabled;
        RebalanceControl rebalanceControl;
        bool bidsEnabled;
    }

    struct FeeRecipient {
        address recipient;
        uint96 portion; // D18{1}
    }

    /// AUCTION_LAUNCHER control over rebalancing
    struct RebalanceControl {
        bool weightControl; // if AUCTION_LAUNCHER can move weights
        PriceControl priceControl; // if/how AUCTION_LAUNCHER can narrow prices
    }

    /// Basket limits for rebalancing
    struct RebalanceLimits {
        uint256 low; // D18{BU/share} (0, 1e27] to buy assets up to
        uint256 spot; // D18{BU/share} (0, 1e27] point estimate to be used in the event of unrestricted caller
        uint256 high; // D18{BU/share} (0, 1e27] to sell assets down to
    }

    /// Range of basket weights for BU definition
    struct WeightRange {
        uint256 low; // D27{tok/BU} [0, 1e54] to buy assets up to
        uint256 spot; // D27{tok/BU} [0, 1e54] point estimate to be used in the event of unrestricted caller
        uint256 high; // D27{tok/BU} [0, 1e54] to sell assets down to
    }

    /// Individual token price ranges
    /// @dev Unit of Account (UoA) can be anything as long as it's consistent; nanoUSD is most common
    struct PriceRange {
        uint256 low; // D27{UoA/tok} (0, 1e45]
        uint256 high; // D27{UoA/tok} (0, 1e45]
    }

    /// Rebalance details for a token
    struct RebalanceDetails {
        bool inRebalance;
        WeightRange weights; // D27{tok/BU} [0, 1e54]
        PriceRange initialPrices; // D27{UoA/tok} (0, 1e45]
    }

    /// Singleton rebalance state
    struct Rebalance {
        uint256 nonce;
        mapping(address token => RebalanceDetails) details;
        RebalanceLimits limits; // D18{BU/share} (0, 1e27]
        uint256 startedAt; // {s} timestamp rebalancing started, inclusive
        uint256 restrictedUntil; // {s} timestamp rebalancing becomes unrestricted, exclusive
        uint256 availableUntil; // {s} timestamp rebalancing ends overall, exclusive
        PriceControl priceControl; // AUCTION_LAUNCHER control over auction pricing
        bool bidsEnabled; // If true, permissionless bids are enabled
    }

    /// 1 running auction at a time; N per rebalance overall
    /// Auction states:
    ///   - UNINITIALIZED: startTime == 0 && endTime == 0
    ///   - PENDING: block.timestamp < startTime
    ///   - OPEN: block.timestamp >= startTime && block.timestamp <= endTime
    ///   - CLOSED: block.timestamp > endTime
    struct Auction {
        uint256 rebalanceNonce;
        mapping(address token => PriceRange) prices; // D27{UoA/tok} (0, 1e45]
        uint256 startTime; // {s} inclusive
        uint256 endTime; // {s} inclusive
    }

    /// Used to mark old storage slots now deprecated
    struct DeprecatedStruct {
        bytes32 EMPTY;
    }

    function distributeFees() external;
}
