// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;
import "./ITrade.sol";
import "./ITrading.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

interface IFolio {
    event TradeApproved(uint256 indexed tradeId, address indexed from, address indexed to, uint256 amount);
    event TradeLaunched(uint256 indexed tradeId);
    event TradeSettled(uint256 indexed tradeId, uint256 toAmount);

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
        uint256 bps;
    }
    function setDemurrageFee(uint256 _demurrageFee) external;
    function setDemurrageRecipients(DemurrageRecipient[] memory _demurrageRecipients) external;
    // function approveTrade(TradeParams memory trade) external;
    // function launchTrade(uint256 _tradeId, TradePrices memory prices) external;
    // function forceSettleTrade(uint256 _tradeId) external;
    // function settleTrade(uint256 _tradeId) external;

    function poke() external;

    function assets() external view returns (address[] memory _assets);
    // ( {tokAddress}, {tok/FU} )
    function folio() external view returns (address[] memory _assets, uint256[] memory _amounts);
    // ( {tokAddress}, {tok} )
    function totalAssets() external view returns (address[] memory _assets, uint256[] memory _amounts);
    // {FU} -> ( {tokAddress}, {tok} )
    function convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) external view returns (address[] memory _assets, uint256[] memory _amounts);

    function previewMint(uint256 shares) external view returns (address[] memory _assets, uint256[] memory _amounts);
    function mint(
        uint256 shares,
        address receiver
    ) external returns (address[] memory _assets, uint256[] memory _amounts);

    function previewRedeem(uint256 shares) external view returns (address[] memory _assets, uint256[] memory _amounts);
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (address[] memory _assets, uint256[] memory _amounts);

    // function collectFee(address recipient) external;
    function collectFees() external;
}
