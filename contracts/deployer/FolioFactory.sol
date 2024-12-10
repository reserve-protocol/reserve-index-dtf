// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { FolioProxyAdmin, FolioProxy } from "@deployer/FolioProxy.sol";

import { IFolioFactory } from "@interfaces/IFolioFactory.sol";
import { Versioned } from "@utils/Versioned.sol";
import { Folio, IFolio } from "@src/Folio.sol";

contract FolioFactory is IFolioFactory, Versioned {
    address public immutable daoFeeRegistry;
    address public immutable versionRegistry;

    address public immutable folioImplementation;

    constructor(address _daoFeeRegistry, address _versionRegistry) {
        daoFeeRegistry = _daoFeeRegistry;
        versionRegistry = _versionRegistry;

        folioImplementation = address(new Folio());
    }

    function createFolio(
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        address owner
    ) external returns (address folio, address proxyAdmin) {
        if (basicDetails.assets.length != basicDetails.amounts.length) {
            revert FolioFactory__LengthMismatch();
        }

        if (basicDetails.assets.length == 0) {
            revert FolioFactory__EmptyAssets();
        }

        FolioProxyAdmin folioAdmin = new FolioProxyAdmin(owner, versionRegistry);
        Folio newFolio = Folio(address(new FolioProxy(folioImplementation, address(folioAdmin))));

        for (uint256 i; i < basicDetails.assets.length; i++) {
            SafeERC20.safeTransferFrom(
                IERC20(basicDetails.assets[i]),
                msg.sender,
                address(newFolio),
                basicDetails.amounts[i]
            );
        }

        newFolio.initialize(basicDetails, additionalDetails, owner);

        return (address(newFolio), address(folioAdmin));
    }
}
