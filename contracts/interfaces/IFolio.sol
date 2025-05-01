// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFolio {
    // === Events ===

    event AuctionOpened(uint256 indexed auctionId, Auction auction);
    event AuctionBid(uint256 indexed auctionId, uint256 sellAmount, uint256 buyAmount);
    event AuctionClosed(uint256 indexed auctionId);
    event AuctionTrustedFillCreated(uint256 indexed auctionId, address filler);

    event FolioFeePaid(address indexed recipient, uint256 amount);
    event ProtocolFeePaid(address indexed recipient, uint256 amount);

    event BasketTokenAdded(address indexed token);
    event BasketTokenRemoved(address indexed token);
    event TVLFeeSet(uint256 newFee, uint256 feeAnnually);
    event MintFeeSet(uint256 newFee);
    event FeeRecipientsSet(FeeRecipient[] recipients);
    event AuctionDelaySet(uint256 newAuctionDelay);
    event AuctionLengthSet(uint256 newAuctionLength);
    event DustAmountSet(address token, uint256 newDustAmount);
    event MandateSet(string newMandate);
    event TrustedFillerRegistrySet(address trustedFillerRegistry, bool isEnabled);
    event FolioDeprecated();

    event RebalanceStarted(
        uint256 nonce,
        address[] tokens,
        WeightRange[] weights,
        PriceRange[] prices,
        uint256 targetBaskets,
        uint256 restrictedUntil,
        uint256 availableUntil,
        bool trustAuctionLauncherPricing
    );
    event RebalanceEnded(uint256 nonce);

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
    error Folio__InvalidAuctionPrices();
    error Folio__InvalidTargets();
    error Folio__InvalidWeights();
    error Folio__InvalidSellLimit();
    error Folio__InvalidBuyLimit();
    error Folio__AuctionCannotBeOpenedWithoutRestriction();
    error Folio__AuctionNotOngoing();
    error Folio__AuctionCollision();
    error Folio__InvalidPrices();
    error Folio__SlippageExceeded();
    error Folio__InsufficientSellAvailable();
    error Folio__InsufficientBid();
    error Folio__InsufficientSharesOut();
    error Folio__InvalidAuctionTokens();
    error Folio__InvalidAuctionDelay();
    error Folio__TooManyFeeRecipients();
    error Folio__InvalidArrayLengths();
    error Folio__InvalidTransferToSelf();

    error Folio__InvalidRegistry();
    error Folio__TrustedFillerRegistryNotEnabled();
    error Folio__TrustedFillerRegistryAlreadySet();

    error Folio__InvalidTTL();
    error Folio__NotRebalancing();
    error Folio__InvalidRebalanceNonce();
    error Folio__PricingNotTrusted();
    error Folio__TokenNotInRebalance();

    // === Structures ===

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

    struct FolioRegistryFlags {
        bool trustedFillerEnabled;
    }

    struct FeeRecipient {
        address recipient;
        uint96 portion; // D18{1}
    }

    struct RebalanceLimits {
        uint256 spot; // D18{BU/share} // the ideal destination (0, 1e36]
        uint256 low; // D18{BU/share} // to buy assets up to (0, 1e36]
        uint256 high; // D18{BU/share} // to sell assets down to (0, 1e36]
    }

    struct WeightRange {
        uint256 spot; // D27{tok/BU} [0, 1e54]
        uint256 low; // D27{tok/BU} [0, 1e54]
        uint256 high; // D27{tok/BU} [0, 1e54]
    }

    struct PriceRange {
        uint256 low; // D27{UoA/tok}
        uint256 high; // D27{UoA/tok}
    }

    struct RebalanceDetails {
        bool inRebalance;
        WeightRange weights; // D27{tok/BU} [0, 1e54]
        PriceRange prices; // D27{UoA/tok} prices can be in any Unit of Account as long as it's consistent (0, 1e54]
    }

    struct Rebalance {
        uint256 nonce;
        mapping(address token => RebalanceDetails) details;
        RebalanceLimits limits; // D18{BU/share} (0, 1e36]
        uint256 startedAt; // {s} timestamp rebalancing started, inclusive
        uint256 restrictedUntil; // {s} timestamp rebalancing is unrestricted to everyone, exclusive
        uint256 availableUntil; // {s} timestamp rebalancing ends overall, exclusive
        bool trustAuctionLauncherPricing; // whether prices can be revised by the AUCTION_LAUNCHER
    }

    /// Auction states:
    ///   - APPROVED: startTime == 0 && endTime == 0
    ///   - OPEN: block.timestamp >= startTime && block.timestamp <= endTime
    ///   - CLOSED: block.timestamp > endTime
    struct Auction {
        uint256 rebalanceNonce;
        uint256 sellLimit; // D18{BU/share} (0, 1e36]
        uint256 buyLimit; // D18{BU/share} (0, 1e36]
        uint256 startTime; // {s} inclusive
        uint256 endTime; // {s} inclusive
    }

    /// Used to mark old storage slots now deprecated
    struct DeprecatedStruct {
        bytes32 EMPTY;
    }

    function distributeFees() external;
}
