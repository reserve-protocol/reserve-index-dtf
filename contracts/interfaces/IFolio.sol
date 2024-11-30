// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFolio {
    // TODO
    // Events
    // event TradeApproved(uint256 indexed tradeId, address indexed from, address indexed to, uint256 amount);
    // event TradeLaunched(uint256 indexed tradeId);
    // event TradeSettled(uint256 indexed tradeId, uint256 toAmount);

    // Errors
    error Folio__BasketAlreadyInitialized();

    error Folio__FeeRecipientInvalidAddress();
    error Folio__FeeRecipientInvalidFeeShare();
    error Folio__BadFeeTotal();
    error Folio__FeeTooHigh();

    error Folio__InvalidAsset();
    error Folio__InvalidAssetAmount(address asset);

    error Folio__InvalidDutchAuctionLength();
    error Folio__InvalidTradeId();
    error Folio__InvalidSellAmount();
    error Folio__TradeNotApproved();
    error Folio__TradeNotOngoing();
    error Folio__InvalidStartPrice();
    error Folio__InvalidEndPrice();
    error Folio__TradeTimeout();
    error Folio__SlippageExceeded();

    // enum TradeKind {
    //     ATOMIC_SWAP,
    //     DUTCH_AUCTION
    // }

    // enum TradeStatus {
    //     APPROVED,
    //     OPEN,
    //     CLOSED
    // }

    // Structures
    struct FeeRecipient {
        address recipient;
        uint96 share;
    }

    struct Trade {
        uint256 id;
        IERC20 sell;
        IERC20 buy;
        uint256 sellAmount; // {sellTok}
        uint256 startPrice; // D18{buyTok/sellTok}
        uint256 endPrice; // D18{buyTok/sellTok}
        uint256 launchTimeout; // {s}
        uint256 start; // {s} inclusive
        uint256 end; // {s} inclusive
    }

    function distributeFees() external; // @audit Review, needs to be called from FolioFeeRegistry
}
