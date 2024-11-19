// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Folio } from "./Folio.sol";

contract FolioFactory {
    address public daoFeeRegistry;
    address public dutchTradeImplementation;

    constructor(address _daoFeeRegistry, address _dutchTradeImplementation) {
        daoFeeRegistry = _daoFeeRegistry;
        dutchTradeImplementation = _dutchTradeImplementation;
    }

    function createFolio(
        string memory name,
        string memory symbol,
        address[] memory assets,
        uint256[] memory amounts,
        uint256 initShares,
        uint256 demurrageFee,
        Folio.DemurrageRecipient[] memory demurrageRecipients
    ) external returns (address) {
        Folio newFolio = new Folio(
            name,
            symbol,
            demurrageFee,
            demurrageRecipients,
            daoFeeRegistry,
            dutchTradeImplementation
        );

        for (uint256 i; i < assets.length; i++) {
            IERC20(assets[i]).transferFrom(msg.sender, address(newFolio), amounts[i]);
        }

        newFolio.initialize(assets, msg.sender, initShares);
        newFolio.grantRole(newFolio.DEFAULT_ADMIN_ROLE(), msg.sender);

        return address(newFolio);
    }
}
