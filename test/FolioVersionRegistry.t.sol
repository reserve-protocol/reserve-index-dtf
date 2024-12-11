// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { IFolioFactory } from "@interfaces/IFolioFactory.sol";
import { FolioFactoryV2 } from "./utils/upgrades/FolioFactoryV2.sol";
import { IFolioVersionRegistry } from "contracts/interfaces/IFolioVersionRegistry.sol";
import { FolioVersionRegistry } from "contracts/deployer/FolioVersionRegistry.sol";
import "./base/BaseTest.sol";

contract FolioVersionRegistryTest is BaseTest {
    function test_constructor() public {
        FolioVersionRegistry folioVersionRegistry = new FolioVersionRegistry(IRoleRegistry(address(roleRegistry)));
        assertEq(address(folioVersionRegistry.roleRegistry()), address(roleRegistry));

        // getLatestVersion() reverts until a version is registered
        vm.expectRevert();
        folioVersionRegistry.getLatestVersion();
    }

    function test_cannotCreateVersionRegistryWithInvalidRoleRegistry() public {
        vm.expectRevert(IFolioVersionRegistry.VersionRegistry__ZeroAddress.selector);
        new FolioVersionRegistry(IRoleRegistry(address(0)));
    }

    function test_getLatestVersion() public {
        (bytes32 versionHash, string memory version, IFolioFactory regfolioFactory, bool deprecated) = versionRegistry
            .getLatestVersion();

        assertEq(versionHash, keccak256("1.0.0"));
        assertEq(version, "1.0.0");
        assertEq(address(regfolioFactory), address(folioFactory));
        assertEq(deprecated, false);
    }

    function test_getImplementationForVersion() public {
        address impl = versionRegistry.getImplementationForVersion(keccak256("1.0.0"));
        assertEq(impl, folioFactory.folioImplementation());

        // reverts if version is not registered
        vm.expectRevert();
        versionRegistry.getImplementationForVersion(keccak256("2.0.0"));
    }

    function test_registerVersion() public {
        // deploy and register new factory with new version
        FolioFactory newFactoryV2 = new FolioFactoryV2(address(daoFeeRegistry), address(versionRegistry));
        vm.expectEmit(true, true, false, true);
        emit IFolioVersionRegistry.VersionRegistered(keccak256("2.0.0"), newFactoryV2);
        versionRegistry.registerVersion(newFactoryV2);

        // get implementation for new version
        address impl = versionRegistry.getImplementationForVersion(keccak256("2.0.0"));
        assertEq(impl, newFactoryV2.folioImplementation());

        // Retrieves the latest version
        (bytes32 versionHash, string memory version, IFolioFactory regfolioFactory, bool deprecated) = versionRegistry
            .getLatestVersion();
        assertEq(versionHash, keccak256("2.0.0"));
        assertEq(version, "2.0.0");
        assertEq(address(regfolioFactory), address(newFactoryV2));
        assertEq(deprecated, false);
    }

    function test_cannotRegisterExistingVersion() public {
        // attempt to re-register
        vm.expectRevert(abi.encodeWithSelector(IFolioVersionRegistry.VersionRegistry__InvalidRegistration.selector));
        versionRegistry.registerVersion(folioFactory);

        // attempt to register new factory with same version
        FolioFactory newFactory = new FolioFactory(address(daoFeeRegistry), address(versionRegistry));
        vm.expectRevert(abi.encodeWithSelector(IFolioVersionRegistry.VersionRegistry__InvalidRegistration.selector));
        versionRegistry.registerVersion(newFactory);
    }

    function test_cannotRegisterVersionIfNotOwner() public {
        FolioFactory newFactoryV2 = new FolioFactoryV2(address(daoFeeRegistry), address(versionRegistry));

        vm.prank(user1);
        vm.expectRevert(IFolioVersionRegistry.VersionRegistry__InvalidCaller.selector);
        versionRegistry.registerVersion(newFactoryV2);
    }

    function test_cannotRegisterVersionWithZeroAddress() public {
        vm.expectRevert(IFolioVersionRegistry.VersionRegistry__ZeroAddress.selector);
        versionRegistry.registerVersion(IFolioFactory(address(0)));
    }

    function test_deprecateVersion() public {
        // get latest version
        (bytes32 versionHash, string memory version, IFolioFactory regfolioFactory, bool deprecated) = versionRegistry
            .getLatestVersion();
        assertEq(versionHash, keccak256("1.0.0"));
        assertEq(version, "1.0.0");
        assertEq(address(regfolioFactory), address(folioFactory));
        assertEq(deprecated, false);

        // deprecate version
        vm.expectEmit(true, false, false, true);
        emit IFolioVersionRegistry.VersionDeprecated(keccak256("1.0.0"));
        versionRegistry.deprecateVersion(keccak256("1.0.0"));

        // now its deprecated
        (versionHash, version, regfolioFactory, deprecated) = versionRegistry.getLatestVersion();
        assertEq(versionHash, keccak256("1.0.0"));
        assertEq(version, "1.0.0");
        assertEq(address(regfolioFactory), address(folioFactory));
        assertEq(deprecated, true);
    }

    function test_cannotDeprecateVersionAlreadyDeprecated() public {
        // deprecate version
        versionRegistry.deprecateVersion(keccak256("1.0.0"));

        // now its deprecated
        (bytes32 versionHash, string memory version, IFolioFactory regfolioFactory, bool deprecated) = versionRegistry
            .getLatestVersion();
        assertEq(versionHash, keccak256("1.0.0"));
        assertEq(version, "1.0.0");
        assertEq(address(regfolioFactory), address(folioFactory));
        assertEq(deprecated, true);

        // attempt to deprecate version again
        vm.expectRevert(abi.encodeWithSelector(IFolioVersionRegistry.VersionRegistry__AlreadyDeprecated.selector));
        versionRegistry.deprecateVersion(keccak256("1.0.0"));
    }

    function test_cannotDeprecateVersionIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert(IFolioVersionRegistry.VersionRegistry__InvalidCaller.selector);
        versionRegistry.deprecateVersion(keccak256("1.0.0"));
    }
}
