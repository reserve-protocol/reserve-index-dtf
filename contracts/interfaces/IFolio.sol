// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFolio {
    // === Events ===

    event AuctionApproved(uint256 indexed auctionId, address indexed from, address indexed to, Auction auction);
    event AuctionOpened(uint256 indexed auctionId, Auction auction);
    event AuctionBid(uint256 indexed auctionId, uint256 sellAmount, uint256 buyAmount);
    event AuctionClosed(uint256 indexed auctionId);

    event FolioFeePaid(address indexed recipient, uint256 amount);
    event ProtocolFeePaid(address indexed recipient, uint256 amount);

    event BasketTokenAdded(address indexed token);
    event BasketTokenRemoved(address indexed token);
    event TVLFeeSet(uint256 newFee, uint256 feeAnnually);
    event MintFeeSet(uint256 newFee);
    event FeeRecipientSet(address indexed recipient, uint96 portion);
    event AuctionDelaySet(uint256 newAuctionDelay);
    event AuctionLengthSet(uint256 newAuctionLength);
    event MandateSet(string newMandate);
    event FolioKilled();

    // === Errors ===

    error Folio__FolioKilled();
    error Folio__Unauthorized();

    error Folio__EmptyAssets();
    error Folio__BasketModificationFailed();

    error Folio__FeeRecipientInvalidAddress();
    error Folio__FeeRecipientInvalidFeeShare();
    error Folio__BadFeeTotal();
    error Folio__TVLFeeTooHigh();
    error Folio__TVLFeeTooLow();
    error Folio__MintFeeTooHigh();
    error Folio__ZeroInitialShares();

    error Folio__InvalidAsset();
    error Folio__InvalidAssetAmount(address asset);

    error Folio__InvalidAuctionLength();
    error Folio__InvalidSellLimit();
    error Folio__InvalidBuyLimit();
    error Folio__AuctionCannotBeOpened();
    error Folio__AuctionCannotBeOpenedPermissionlesslyYet();
    error Folio__AuctionNotOngoing();
    error Folio__AuctionCollision();
    error Folio__InvalidPrices();
    error Folio__AuctionTimeout();
    error Folio__SlippageExceeded();
    error Folio__InsufficientBalance();
    error Folio__InsufficientBid();
    error Folio__ExcessiveBid();
    error Folio__InvalidAuctionTokens();
    error Folio__InvalidAuctionDelay();
    error Folio__InvalidAuctionTTL();
    error Folio__TooManyFeeRecipients();
    error Folio__InvalidArrayLengths();

    // === Structures ===

    struct FolioBasicDetails {
        string name;
        string symbol;
        address[] assets;
        uint256[] amounts; // {tok}
        uint256 initialShares; // {share}
    }

    struct FolioAdditionalDetails {
        uint256 auctionDelay; // {s}
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
        uint256 spot; // D27{buyTok/share}
        uint256 low; // D27{buyTok/share} inclusive
        uint256 high; // D27{buyTok/share} inclusive
    }

    struct Prices {
        uint256 start; // D27{buyTok/sellTok}
        uint256 end; // D27{buyTok/sellTok}
    }

    /// Auction states:
    ///   - APPROVED: start == 0 && end == 0
    ///   - OPEN: block.timestamp >= start && block.timestamp <= end
    ///   - CLOSED: block.timestamp > end
    struct Auction {
        uint256 id;
        IERC20 sell;
        IERC20 buy;
        BasketRange sellLimit; // D27{sellTok/share} min ratio of sell token in the basket, inclusive
        BasketRange buyLimit; // D27{buyTok/share} max ratio of buy token in the basket, exclusive
        Prices prices; // D27{buyTok/sellTok}
        uint256 availableAt; // {s} inclusive
        uint256 launchTimeout; // {s} inclusive
        uint256 start; // {s} inclusive
        uint256 end; // {s} inclusive
        // === Gas optimization ===
        uint256 k; // D18{1} price = startPrice * e ^ -kt
    }

    function distributeFees() external;
}
