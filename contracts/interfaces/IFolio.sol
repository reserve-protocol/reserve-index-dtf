// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ITrade.sol";
import "./ITrading.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

interface IFolio {
    // Events
    event TradeApproved(uint256 indexed tradeId, address indexed from, address indexed to, uint256 amount);
    event TradeLaunched(uint256 indexed tradeId);
    event TradeSettled(uint256 indexed tradeId, uint256 toAmount);

    // Errors
    error Folio_badDemurrageFeeRecipientAddress();
    error Folio_badDemurrageFeeRecipientBps();
    error Folio_badDemurrageFeeTotal();

    error Folio__DemurrageFeeTooHigh();
    error Folio__BasketAlreadyInitialized();

    error Folio__InvalidAsset();
    error Folio__InvalidAssetLength();
    error Folio__InvalidAssetAmount(address asset, uint256 amount);
    error Folio__LengthMismatch();

    // Structures

    // struct TradeParams {
    //     address sell;
    //     address buy;
    //     uint256 amount; // {qFU} 1e18 precision
    // }
    // struct Trade {
    //     TradeParams params;
    //     ITrade trader;
    // }
    struct DemurrageRecipient {
        address recipient;
        uint96 bps;
    }
}
