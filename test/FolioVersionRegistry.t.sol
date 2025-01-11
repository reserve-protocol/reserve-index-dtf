// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { FolioDeployerV2 } from "./utils/upgrades/FolioDeployerV2.sol";
import { IFolioVersionRegistry } from "contracts/interfaces/IFolioVersionRegistry.sol";
import { FolioVersionRegistry } from "contracts/folio/FolioVersionRegistry.sol";
import "./base/BaseTest.sol";

contract FolioVersionRegistryTest is BaseTest {
    function test_constructor() public {
        FolioVersionRegistry folioVersionRegistry = new FolioVersionRegistry(IRoleRegistry(address(roleRegistry)));
        assertEq(address(folioVersionRegistry.roleRegistry()), address(roleRegistry));

        // getLatestVersion() reverts until a version is registered
        vm.expectRevert(IFolioVersionRegistry.VersionRegistry__Unconfigured.selector);
        folioVersionRegistry.getLatestVersion();
    }

    function test_cannotCreateVersionRegistryWithInvalidRoleRegistry() public {
        vm.expectRevert(IFolioVersionRegistry.VersionRegistry__ZeroAddress.selector);
        new FolioVersionRegistry(IRoleRegistry(address(0)));
    }

    function test_getLatestVersion() public view {
        (bytes32 versionHash, string memory version, IFolioDeployer regfolioDeployer, bool deprecated) = versionRegistry
            .getLatestVersion();

        assertEq(versionHash, keccak256("1.0.0"));
        assertEq(version, "1.0.0");
        assertEq(address(regfolioDeployer), address(folioDeployer));
        assertEq(deprecated, false);
    }

    function test_getImplementationForVersion() public {
        address impl = versionRegistry.getImplementationForVersion(keccak256("1.0.0"));
        assertEq(impl, folioDeployer.folioImplementation());

        // reverts if version is not registered
        vm.expectRevert();
        versionRegistry.getImplementationForVersion(keccak256("2.0.0"));
    }

    function test_registerVersion() public {
        // deploy and register new factory with new version
        FolioDeployer newFactoryV2 = new FolioDeployerV2(
            address(daoFeeRegistry),
            address(versionRegistry),
            governanceDeployer
        );
        vm.expectEmit(true, true, false, true);
        emit IFolioVersionRegistry.VersionRegistered(keccak256("2.0.0"), newFactoryV2);
        versionRegistry.registerVersion(newFactoryV2);

        // get implementation for new version
        address impl = versionRegistry.getImplementationForVersion(keccak256("2.0.0"));
        assertEq(impl, newFactoryV2.folioImplementation());

        // Retrieves the latest version
        (bytes32 versionHash, string memory version, IFolioDeployer regfolioDeployer, bool deprecated) = versionRegistry
            .getLatestVersion();
        assertEq(versionHash, keccak256("2.0.0"));
        assertEq(version, "2.0.0");
        assertEq(address(regfolioDeployer), address(newFactoryV2));
        assertEq(deprecated, false);
    }

    function test_cannotRegisterExistingVersion() public {
        // attempt to re-register
        vm.expectRevert(abi.encodeWithSelector(IFolioVersionRegistry.VersionRegistry__InvalidRegistration.selector));
        versionRegistry.registerVersion(folioDeployer);

        // attempt to register new factory with same version
        FolioDeployer newFactory = new FolioDeployer(
            address(daoFeeRegistry),
            address(versionRegistry),
            governanceDeployer
        );
        vm.expectRevert(abi.encodeWithSelector(IFolioVersionRegistry.VersionRegistry__InvalidRegistration.selector));
        versionRegistry.registerVersion(newFactory);
    }

    function test_cannotRegisterVersionIfNotOwner() public {
        FolioDeployer newFactoryV2 = new FolioDeployerV2(
            address(daoFeeRegistry),
            address(versionRegistry),
            governanceDeployer
        );

        vm.prank(user1);
        vm.expectRevert(IFolioVersionRegistry.VersionRegistry__InvalidCaller.selector);
        versionRegistry.registerVersion(newFactoryV2);
    }

    function test_cannotRegisterVersionWithZeroAddress() public {
        vm.expectRevert(IFolioVersionRegistry.VersionRegistry__ZeroAddress.selector);
        versionRegistry.registerVersion(IFolioDeployer(address(0)));
    }

    function test_deprecateVersion() public {
        // get latest version
        (bytes32 versionHash, string memory version, IFolioDeployer regfolioDeployer, bool deprecated) = versionRegistry
            .getLatestVersion();
        assertEq(versionHash, keccak256("1.0.0"));
        assertEq(version, "1.0.0");
        assertEq(address(regfolioDeployer), address(folioDeployer));
        assertEq(deprecated, false);

        // deprecate version
        vm.expectEmit(true, false, false, true);
        emit IFolioVersionRegistry.VersionDeprecated(keccak256("1.0.0"));
        versionRegistry.deprecateVersion(keccak256("1.0.0"));

        // now its deprecated
        (versionHash, version, regfolioDeployer, deprecated) = versionRegistry.getLatestVersion();
        assertEq(versionHash, keccak256("1.0.0"));
        assertEq(version, "1.0.0");
        assertEq(address(regfolioDeployer), address(folioDeployer));
        assertEq(deprecated, true);
    }

    function test_cannotDeprecateVersionAlreadyDeprecated() public {
        // deprecate version
        versionRegistry.deprecateVersion(keccak256("1.0.0"));

        // now its deprecated
        (bytes32 versionHash, string memory version, IFolioDeployer regfolioDeployer, bool deprecated) = versionRegistry
            .getLatestVersion();
        assertEq(versionHash, keccak256("1.0.0"));
        assertEq(version, "1.0.0");
        assertEq(address(regfolioDeployer), address(folioDeployer));
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
