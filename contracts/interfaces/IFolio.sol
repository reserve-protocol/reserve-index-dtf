// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFolio {
    // === Events ===

    event TradeApproved(uint256 indexed tradeId, address indexed from, address indexed to, Trade trade);
    event TradeOpened(uint256 indexed tradeId, Trade trade);
    event TradeBid(uint256 indexed tradeId, uint256 sellAmount, uint256 buyAmount);
    event TradeKilled(uint256 indexed tradeId);

    event FolioFeePaid(address indexed recipient, uint256 amount);
    event ProtocolFeePaid(address indexed recipient, uint256 amount);

    event BasketTokenAdded(address indexed token);
    event BasketTokenRemoved(address indexed token);
    event FolioFeeSet(uint256 newFee, uint256 feeAnnually);
    event MintingFeeSet(uint256 newFee);
    event FeeRecipientSet(address indexed recipient, uint96 portion);
    event TradeDelaySet(uint256 newTradeDelay);
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
    error Folio__FolioFeeTooHigh();
    error Folio__FolioFeeTooLow();
    error Folio__MintingFeeTooHigh();
    error Folio__ZeroInitialShares();

    error Folio__InvalidAsset();
    error Folio__InvalidAssetAmount(address asset);

    error Folio__InvalidAuctionLength();
    error Folio__InvalidSellLimit();
    error Folio__InvalidBuyLimit();
    error Folio__TradeCannotBeOpened();
    error Folio__TradeCannotBeOpenedPermissionlesslyYet();
    error Folio__TradeNotOngoing();
    error Folio__TradeCollision();
    error Folio__InvalidPrices();
    error Folio__TradeTimeout();
    error Folio__SlippageExceeded();
    error Folio__InsufficientBalance();
    error Folio__InsufficientBid();
    error Folio__ExcessiveBid();
    error Folio__InvalidTradeTokens();
    error Folio__InvalidTradeDelay();
    error Folio__InvalidTradeTTL();
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
        uint256 tradeDelay; // {s}
        uint256 auctionLength; // {s}
        FeeRecipient[] feeRecipients;
        uint256 folioFee; // D18{1/s}
        uint256 mintingFee; // D18{1}
        string mandate;
    }

    struct FeeRecipient {
        address recipient;
        uint96 portion; // D18{1}
    }

    struct Range {
        uint256 spot; // D27{buyTok/share}
        uint256 low; // D27{buyTok/share} inclusive
        uint256 high; // D27{buyTok/share} inclusive
    }

    struct Prices {
        uint256 start; // D27{buyTok/sellTok}
        uint256 end; // D27{buyTok/sellTok}
    }

    /// Trade states:
    ///   - APPROVED: start == 0 && end == 0
    ///   - OPEN: block.timestamp >= start && block.timestamp <= end
    ///   - CLOSED: block.timestamp > end
    struct Trade {
        uint256 id;
        IERC20 sell;
        IERC20 buy;
        Range sellLimit; // D27{sellTok/share} min ratio of sell token to shares allowed, inclusive
        Range buyLimit; // D27{buyTok/share} max ratio of buy token to shares allowed, exclusive
        Prices prices; // D27{buyTok/sellTok}
        uint256 availableAt; // {s} inclusive
        uint256 launchTimeout; // {s} inclusive
        uint256 start; // {s} inclusive
        uint256 end; // {s} inclusive
        // === Gas optimization ===
        uint256 k; // D18{1} price = startPrice * e ^ -kt
    }

    struct AuctionConfig {
        Range sellLimit; // D27{sellTok/share} min ratio of sell token to shares allowed, inclusive
        Range buyLimit; // D27{buyTok/share} min ratio of buy token to shares allowed, exclusive
        uint256 startPrice; // D27{buyTok/sellTok}
        uint256 endPrice; // D27{buyTok/sellTok}
    }

    function distributeFees() external;
}
