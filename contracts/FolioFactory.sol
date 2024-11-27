// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Versioned } from "@utils/Versioned.sol";
import { Folio } from "@src/Folio.sol";

contract FolioFactory is Versioned {
    address public immutable daoFeeRegistry;
    address public immutable dutchTradeImplementation;

    address public immutable folioImplementation;

    error FolioFactory__LengthMismatch();

    constructor(address _daoFeeRegistry, address _dutchTradeImplementation) {
        daoFeeRegistry = _daoFeeRegistry;
        dutchTradeImplementation = _dutchTradeImplementation;

        folioImplementation = address(new Folio());
    }

    function createFolio(
        string memory name,
        string memory symbol,
        address[] memory assets,
        uint256[] memory amounts,
        uint256 initShares,
        Folio.FeeRecipient[] memory feeRecipients,
        uint256 folioFee,
        address governor
    ) external returns (address) {
        if (assets.length != amounts.length) {
            revert FolioFactory__LengthMismatch();
        }

        Folio newFolio = Folio(address(new TransparentUpgradeableProxy(folioImplementation, address(governor), "")));

        for (uint256 i; i < assets.length; i++) {
            SafeERC20.safeTransferFrom(IERC20(assets[i]), msg.sender, address(newFolio), amounts[i]);
        }

        newFolio.initialize(
            name,
            symbol,
            dutchTradeImplementation,
            daoFeeRegistry,
            feeRecipients,
            folioFee,
            assets,
            msg.sender,
            initShares,
            governor
        );
        return address(newFolio);
    }
}
