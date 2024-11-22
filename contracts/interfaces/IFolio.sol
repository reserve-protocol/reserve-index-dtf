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
    error Folio__BasketAlreadyInitialized();

    error Folio__FeeRecipientInvalidAddress();
    error Folio__FeeRecipientInvalidFeeShare();
    error Folio__BadFeeTotal();
    error Folio__FeeTooHigh();

    error Folio__InvalidAsset();
    error Folio__InvalidAssetAmount(address asset);

    // Structures
    struct FeeRecipient {
        address recipient;
        uint96 share;
    }

    function distributeFees() external; // @audit Review, needs to be called from FolioFeeRegistry
}
