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
        BasketRange[] weights,
        Prices[] prices,
        uint256 restrictedUntil,
        uint256 availableUntil
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
    error Folio__InvalidLimits();
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

    error Folio__TrustedFillerRegistryNotEnabled();
    error Folio__TrustedFillerRegistryAlreadySet();

    error Folio__InvalidTTL();
    error Folio__NotRebalancing();

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

    struct FeeRecipient {
        address recipient;
        uint96 portion; // D18{1}
    }

    struct BasketRange {
        uint256 spot; // D27{tok/share}
        uint256 low; // D27{tok/share} inclusive
        uint256 high; // D27{tok/share} inclusive
    }

    struct Prices {
        uint256 low; // D27{UoA/tok}
        uint256 high; // D27{UoA/tok}
    }

    struct RebalanceDetails {
        bool inRebalance;
        BasketRange limits; // D27{tok/share}
        Prices prices; // D27{UoA/tok} prices can be in any Unit of Account as long as it's consistent
    }

    struct Rebalance {
        uint256 nonce;
        mapping(address token => RebalanceDetails) details;
        uint256 startedAt; // {s} inclusive, timestamp rebalancing started
        uint256 restrictedUntil; // {s} exclusive, timestamp rebalancing is unrestricted to everyone
        uint256 availableUntil; // {s} exclusive, timestamp rebalancing ends overall
    }

    /// Auction states:
    ///   - APPROVED: startTime == 0 && endTime == 0
    ///   - OPEN: block.timestamp >= startTime && block.timestamp <= endTime
    ///   - CLOSED: block.timestamp > endTime
    struct Auction {
        uint256 rebalanceNonce;
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 sellLimit; // D27{sellTok/share} min ratio of sell token in the basket, inclusive
        uint256 buyLimit; // D27{buyTok/share} max ratio of buy token in the basket, exclusive
        uint256 startPrice; // D27{buyTok/sellTok}
        uint256 endPrice; // D27{buyTok/sellTok}
        uint256 startTime; // {s} inclusive
        uint256 endTime; // {s} inclusive
    }

    /// Used to mark old storage slots now deprecated
    struct DeprecatedStruct {
        bytes32 EMPTY;
    }

    function distributeFees() external;
}
