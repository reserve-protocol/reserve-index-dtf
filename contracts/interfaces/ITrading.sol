// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ITrade.sol";

struct TradePrices {
    uint256 sellLow; // {UoA/sellTok} can be 0
    uint256 sellHigh; // {UoA/sellTok} should not be 0
    uint256 buyLow; // {UoA/buyTok} should not be 0
    uint256 buyHigh; // {UoA/buyTok} should not be 0 or FIX_MAX
}

/**
 * @title ITrading
 * @notice Common events and refresher function for all Trading contracts
 */
interface ITrading {
    event MaxTradeSlippageSet(uint256 oldVal, uint256 newVal);
    event MinTradeVolumeSet(uint256 oldVal, uint256 newVal);

    /// Emitted when a trade is started
    /// @param trade The one-time-use trade contract that was just deployed
    /// @param sell The token to sell
    /// @param buy The token to buy
    /// @param sellAmount {qSellTok} The quantity of the selling token
    /// @param minBuyAmount {qBuyTok} The minimum quantity of the buying token to accept
    event TradeStarted(
        ITrade indexed trade,
        IERC20 indexed sell,
        IERC20 indexed buy,
        uint256 sellAmount,
        uint256 minBuyAmount
    );

    /// Emitted after a trade ends
    /// @param trade The one-time-use trade contract
    /// @param sell The token to sell
    /// @param buy The token to buy
    /// @param sellAmount {qSellTok} The quantity of the token sold
    /// @param buyAmount {qBuyTok} The quantity of the token bought
    event TradeSettled(
        ITrade indexed trade,
        IERC20 indexed sell,
        IERC20 indexed buy,
        uint256 sellAmount,
        uint256 buyAmount
    );

    /// Forcibly settle a trade, losing all value
    /// Should only be called in case of censorship
    /// @param trade The trade address itself
    /// @custom:governance
    function forceSettleTrade(ITrade trade) external;

    /// Settle a single trade, expected to be used with multicall for efficient mass settlement
    /// @param sell The sell token in the trade
    /// @return The trade settled
    /// @custom:refresher
    function settleTrade(IERC20 sell) external returns (ITrade);

    /// @return {%} The maximum trade slippage acceptable
    function maxTradeSlippage() external view returns (uint256);

    /// @return {UoA} The minimum trade volume in UoA, applies to all assets
    function minTradeVolume() external view returns (uint256);

    /// @return The ongoing trade for a sell token, or the zero address
    function trades(IERC20 sell) external view returns (ITrade);

    /// @return The number of ongoing trades open
    function tradesOpen() external view returns (uint48);

    /// @return The number of total trades ever opened
    function tradesNonce() external view returns (uint256);
}

interface TestITrading is ITrading {
    /// @custom:governance
    function setMaxTradeSlippage(uint256 val) external;

    /// @custom:governance
    function setMinTradeVolume(uint256 val) external;
}