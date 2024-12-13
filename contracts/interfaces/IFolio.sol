// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFolio {
    // === Events ===

    event TradeApproved(
        uint256 indexed tradeId,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 startPrice
    );
    event TradeOpened(uint256 indexed tradeId, uint256 startPrice, uint256 endPrice, uint256 start, uint256 end);
    event Bid(uint256 indexed tradeId, uint256 sellAmount, uint256 buyAmount);
    event TradeKilled(uint256 indexed tradeId);

    event BasketTokenAdded(address indexed token);
    event BasketTokenRemoved(address indexed token);
    event FolioFeeSet(uint256 newFee);
    event FeeRecipientSet(address indexed recipient, uint96 portion);
    event TradeDelaySet(uint256 newTradeDelay);
    event AuctionLengthSet(uint256 newAuctionLength);

    // === Errors ===

    error Folio__BasketAlreadyInitialized();
    error Folio__EmptyAssets();

    error Folio__FeeRecipientInvalidAddress();
    error Folio__FeeRecipientInvalidFeeShare();
    error Folio__BadFeeTotal();
    error Folio__FeeTooHigh();

    error Folio__InvalidAsset();
    error Folio__InvalidAssetAmount(address asset);

    error Folio__InvalidAuctionLength();
    error Folio__InvalidTradeId();
    error Folio__InvalidSellAmount();
    error Folio__TradeCannotBeOpened();
    error Folio__TradeCannotBeOpenedPermissionlesslyYet();
    error Folio__TradeNotOngoing();
    error Folio__InvalidPrices();
    error Folio__TradeTimeout();
    error Folio__SlippageExceeded();
    error Folio__InsufficientBalance();
    error Folio__InsufficientBid();
    error Folio__InvalidTradeTokens();
    error Folio__InvalidTradeDelay();
    error Folio__InvalidTradeTTL();
    error Folio__TooManyFeeRecipients();

    // === Structures ===

    struct FolioBasicDetails {
        string name;
        string symbol;
        address[] assets;
        uint256[] amounts;
        uint256 initialShares;
    }

    struct FolioAdditionalDetails {
        uint256 tradeDelay;
        uint256 auctionLength;
        FeeRecipient[] feeRecipients;
        uint256 folioFee;
    }

    struct FeeRecipient {
        address recipient;
        uint96 portion; // D18{1} <= 1e18
    }

    /// Trade states:
    ///   - APPROVED: start == 0 && end == 0
    ///   - OPEN: block.timestamp >= start && block.timestamp <= end
    ///   - CLOSED: block.timestamp > end
    struct Trade {
        uint256 id;
        IERC20 sell;
        IERC20 buy;
        uint256 sellAmount; // {sellTok}
        uint256 startPrice; // D18{buyTok/sellTok}
        uint256 endPrice; // D18{buyTok/sellTok}
        uint256 availableAt; // {s} inclusive
        uint256 launchTimeout; // {s} inclusive
        uint256 start; // {s} inclusive
        uint256 end; // {s} inclusive
        // === Gas optimization ===
        uint256 k; // {1} price = startPrice * e ^ -kt
    }

    function distributeFees() external; // @audit Review, needs to be called from FolioDAOFeeRegistry
}
