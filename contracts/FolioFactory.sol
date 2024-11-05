pragma solidity 0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Folio } from "./Folio.sol";

contract FolioFactory {
    constructor() {}
    function createFolio(
        string memory name,
        string memory symbol,
        address[] memory assets,
        uint256[] memory amounts,
        uint256 demurrageFee,
        Folio.DemurrageRecipient[] memory demurrageRecipients,
        address dutchTradeImplementation
    ) external returns (address) {
        Folio newFolio = new Folio(name, symbol, demurrageFee, demurrageRecipients, dutchTradeImplementation);
        for (uint256 i; i < assets.length; i++) {
            IERC20(assets[i]).transferFrom(msg.sender, address(this), amounts[i]);
            IERC20(assets[i]).approve(address(newFolio), amounts[i]);
        }
        newFolio.initialize(assets, amounts);
        newFolio.setOwner(msg.sender);
        return address(newFolio);
    }
}
