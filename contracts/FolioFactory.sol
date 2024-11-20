// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
        Folio.FeeRecipient[] memory feeRecipients,
        uint256 folioFee
    ) external returns (address) {
        Folio newFolio = new Folio(name, symbol, feeRecipients, folioFee, daoFeeRegistry, dutchTradeImplementation);

        for (uint256 i; i < assets.length; i++) {
            SafeERC20.safeTransferFrom(IERC20(assets[i]), msg.sender, address(newFolio), amounts[i]);
        }

        newFolio.initialize(assets, msg.sender, initShares);

        newFolio.grantRole(newFolio.DEFAULT_ADMIN_ROLE(), msg.sender);
        newFolio.revokeRole(newFolio.DEFAULT_ADMIN_ROLE(), address(this));

        return address(newFolio);
    }
}
