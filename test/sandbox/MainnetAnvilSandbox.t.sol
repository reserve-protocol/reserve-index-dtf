// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { Folio } from "@src/Folio.sol";
import { IFolio } from "@interfaces/IFolio.sol";

import { MainnetAnvilBootstrap } from "../../script/sandbox/MainnetAnvilSandbox.s.sol";
import { UpgradeSpell_6_0_0 } from "../../script/sandbox/UpgradeSpell_6_0_0.sol";

contract BootstrapHarness is MainnetAnvilBootstrap {
    function useRealV6Deployer(address deployer) external returns (address) {
        return _useRealV6Deployer(deployer);
    }
}

contract MockRoleRegistry {
    mapping(address => bool) public isOwner;

    function setOwner(address account) external {
        isOwner[account] = true;
    }
}

/// Etched at the canonical version-registry address; mirrors the calls the bootstrap makes.
contract MockVersionRegistry {
    address public roleRegistry;
    mapping(bytes32 => address) public deployments;
    mapping(bytes32 => bool) public isDeprecated;

    function setRoleRegistry(address registry) external {
        roleRegistry = registry;
    }

    function setDeployment(bytes32 versionHash, address deployer) external {
        deployments[versionHash] = deployer;
    }

    function deprecate(bytes32 versionHash) external {
        isDeprecated[versionHash] = true;
    }

    function registerVersion(address deployer) external {
        require(MockRoleRegistry(roleRegistry).isOwner(msg.sender), "mock: not owner");
        bytes32 versionHash = keccak256(bytes(MockFolioDeployer(deployer).version()));
        require(deployments[versionHash] == address(0), "mock: already registered");
        deployments[versionHash] = deployer;
    }
}

contract MockFolioDeployer {
    string public version;
    address public versionRegistry;

    constructor(string memory _version, address _versionRegistry) {
        version = _version;
        versionRegistry = _versionRegistry;
    }
}

contract MainnetAnvilRealDeployerTest is Test {
    address internal constant VERSION_REGISTRY = 0xA665b273997F70b647B66fa7Ed021287544849dB;
    address internal constant ROLE_REGISTRY_OWNER = 0xe8259842e71f4E44F2F68D6bfbC15EDA56E63064;
    bytes32 internal constant VERSION_6_0_0 = keccak256("6.0.0");

    BootstrapHarness internal harness;
    MockVersionRegistry internal registry;
    MockRoleRegistry internal roleRegistry;
    address internal deployer;

    function setUp() public {
        harness = new BootstrapHarness();
        vm.etch(VERSION_REGISTRY, address(new MockVersionRegistry()).code);
        registry = MockVersionRegistry(VERSION_REGISTRY);
        roleRegistry = new MockRoleRegistry();
        registry.setRoleRegistry(address(roleRegistry));
        roleRegistry.setOwner(ROLE_REGISTRY_OWNER);
        deployer = address(new MockFolioDeployer("6.0.0", VERSION_REGISTRY));
    }

    function test_registersUnregisteredRealDeployerThroughCanonicalOwner() public {
        assertEq(harness.useRealV6Deployer(deployer), deployer);
        assertEq(registry.deployments(VERSION_6_0_0), deployer);
    }

    function test_reusesExistingRegistrationOfTheSameDeployer() public {
        registry.setDeployment(VERSION_6_0_0, deployer);
        assertEq(harness.useRealV6Deployer(deployer), deployer);
        assertEq(registry.deployments(VERSION_6_0_0), deployer);
    }

    function test_refusesToAdoptADifferentRegisteredDeployer() public {
        registry.setDeployment(VERSION_6_0_0, address(new MockFolioDeployer("6.0.0", VERSION_REGISTRY)));
        vm.expectRevert(bytes("6.0.0 is registered to a different deployer than SANDBOX_V6_DEPLOYER; reset the fork"));
        harness.useRealV6Deployer(deployer);
    }

    function test_rejectsDeployerWithoutCode() public {
        vm.expectRevert(bytes("SANDBOX_V6_DEPLOYER has no code on this fork: fork at or after its creation block"));
        harness.useRealV6Deployer(makeAddr("not-yet-deployed"));
    }

    function test_rejectsNon600Deployer() public {
        address v5 = address(new MockFolioDeployer("5.0.0", VERSION_REGISTRY));
        vm.expectRevert(bytes("SANDBOX_V6_DEPLOYER version() is not 6.0.0"));
        harness.useRealV6Deployer(v5);
    }

    function test_rejectsDeployerOnAnotherRegistry() public {
        address other = address(new MockFolioDeployer("6.0.0", makeAddr("other-registry")));
        vm.expectRevert(bytes("SANDBOX_V6_DEPLOYER uses a different version registry"));
        harness.useRealV6Deployer(other);
    }

    function test_requiresCanonicalOwnerToRegister() public {
        MockRoleRegistry noOwner = new MockRoleRegistry();
        registry.setRoleRegistry(address(noOwner));
        vm.expectRevert(bytes("canonical role-registry owner is not authorized"));
        harness.useRealV6Deployer(deployer);
    }

    function test_rejectsDeprecated600() public {
        registry.setDeployment(VERSION_6_0_0, deployer);
        registry.deprecate(VERSION_6_0_0);
        vm.expectRevert(bytes("6.0.0 is deprecated in the version registry"));
        harness.useRealV6Deployer(deployer);
    }
}

contract MainnetAnvilSandboxTest is Test {
    string internal constant SPDX_LINE = "// SPDX-License-Identifier: MIT\n";
    string internal constant SPELL_HEADER =
        "// Sandbox copy of reserve-protocol/reserve-index-dtf contracts/spells/upgrades/UpgradeSpell_6_0_0.sol\n"
        "// at commit e69f6eaaf9678aa575bd502d8f235f8bdd11eb78 (branch upgrade-spell-6.0.0).\n"
        "// Everything from the SPDX line down is byte-for-byte upstream; run.sh and MainnetAnvilSandboxTest pin its sha256.\n";
    // sha256 of `git show e69f6ea:contracts/spells/upgrades/UpgradeSpell_6_0_0.sol`; run.sh pins the same value.
    bytes32 internal constant UPSTREAM_SPELL_SHA256 =
        0x0c3a42f34fc178d83ffa9f8842d3a220fbd18fd564b94290f7354ea22d16c531;

    function test_upgradeSpellSourceIsExactUpstreamCommit() public view {
        string[] memory parts = vm.split(vm.readFile("script/sandbox/UpgradeSpell_6_0_0.sol"), SPDX_LINE);
        assertEq(parts.length, 2, "exactly one SPDX line");
        assertEq(parts[0], SPELL_HEADER, "provenance header");
        assertEq(sha256(bytes(string.concat(SPDX_LINE, parts[1]))), UPSTREAM_SPELL_SHA256, "upstream body");
    }

    function test_runnerPinsTheSameSpellSource() public view {
        string memory runner = vm.readFile("script/sandbox/run.sh");
        assertTrue(vm.contains(runner, 'SPELL_SOURCE_COMMIT="e69f6eaaf9678aa575bd502d8f235f8bdd11eb78"'));
        assertTrue(
            vm.contains(
                runner,
                'SPELL_SOURCE_SHA256="0c3a42f34fc178d83ffa9f8842d3a220fbd18fd564b94290f7354ea22d16c531"'
            )
        );
    }

    /// run.sh drives these through cast by signature string; bind each string to the compiled 6.0.0 Folio.
    function test_completionSignaturesMatchFolio() public view {
        assertEq(Folio.endRebalance.selector, bytes4(keccak256("endRebalance(uint256)")));
        assertEq(Folio.closeAuction.selector, bytes4(keccak256("closeAuction(uint256)")));
        assertEq(Folio.openAuctionUnrestricted.selector, bytes4(keccak256("openAuctionUnrestricted(uint256)")));
        assertEq(Folio.bid.selector, bytes4(keccak256("bid(uint256,address,address,uint256,uint256,bool,bytes)")));
        assertEq(Folio.getBid.selector, bytes4(keccak256("getBid(uint256,address,address,uint256)")));
        assertEq(Folio.getAuctionPrice.selector, bytes4(keccak256("getAuctionPrice(uint256,address)")));
        assertEq(Folio(address(0)).auctions.selector, bytes4(keccak256("auctions(uint256)")));
    }

    /// The fixture records only RebalanceEnded(uint256) with an unindexed nonce; guard against upstream drift.
    function test_completionEventSignatures() public pure {
        assertEq(IFolio.RebalanceEnded.selector, keccak256("RebalanceEnded(uint256)"));
        assertEq(IFolio.AuctionClosed.selector, keccak256("AuctionClosed(uint256)"));
        assertEq(IFolio.AuctionBid.selector, keccak256("AuctionBid(uint256,address,address,uint256,uint256)"));
    }

    function test_upgradeActionSelectors() public pure {
        assertEq(uint32(bytes4(keccak256("registerSelectors((address,bytes4[])[])"))), uint32(0x39535e96));
        assertEq(uint32(bytes4(keccak256("unregisterSelectors((address,bytes4[])[])"))), uint32(0x3bb9e672));
        assertEq(uint32(bytes4(keccak256("transferOwnership(address)"))), uint32(0xf2fde38b));
        assertEq(uint32(UpgradeSpell_6_0_0.cast.selector), uint32(0x2aa6b211));
    }

    function test_executionScenarioSelectors() public pure {
        assertEq(
            uint32(
                bytes4(
                    keccak256(
                        "startRebalance((address,(uint256,uint256,uint256),(uint256,uint256),uint256,bool)[],(uint256,uint256,uint256),uint256,uint256)"
                    )
                )
            ),
            uint32(0x207c8eed)
        );
        assertEq(
            uint32(
                bytes4(
                    keccak256(
                        "startRebalance(uint256,(address,(uint256,uint256,uint256),(uint256,uint256),uint256,bool)[],(uint256,uint256,uint256),uint256,uint256,uint256)"
                    )
                )
            ),
            uint32(0xc1e54b89)
        );
        assertEq(
            bytes4(
                keccak256(
                    "openAuction(uint256,address[],(uint256,uint256,uint256)[],(uint256,uint256)[],(uint256,uint256,uint256))"
                )
            ),
            bytes4(0x3c46570f)
        );
        assertEq(
            bytes4(
                keccak256(
                    "openAuction(uint256,address[],(uint256,uint256,uint256)[],(uint256,uint256)[],(uint256,uint256,uint256),uint256)"
                )
            ),
            bytes4(0x9bd97b3e)
        );
        assertEq(bytes4(keccak256("proposeOptimistic(address[],uint256[],bytes[],string)")), bytes4(0x50979327));
    }
}
