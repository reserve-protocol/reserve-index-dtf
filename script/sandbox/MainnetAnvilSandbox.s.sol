// SPDX-License-Identifier: MIT
// solhint-disable no-console
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";

import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";
import { IReserveOptimisticGovernorDeployer } from "@reserve-protocol/reserve-governor/contracts/interfaces/IDeployer.sol";
import { OPTIMISTIC_PROPOSER_ROLE, PROPOSER_ROLE } from "@reserve-protocol/reserve-governor/contracts/utils/Constants.sol";

import { Folio } from "@src/Folio.sol";
import { IFolio } from "@interfaces/IFolio.sol";
import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { FolioDeployer } from "@deployer/FolioDeployer.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { FolioVersionRegistry } from "@folio/FolioVersionRegistry.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";
import { DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER } from "@utils/Constants.sol";
import { AUCTION_LAUNCHER, MAX_WEIGHT } from "@utils/Constants.sol";

import { ISelectorRegistry_6_0_0, START_REBALANCE_5_0_0, START_REBALANCE_6_0_0, UpgradeSpell_6_0_0, VERSION_6_0_0 } from "./UpgradeSpell_6_0_0.sol";

interface IWETH is IERC20Metadata {
    function deposit() external payable;
}

interface IStakingVaultSandbox is IERC20 {
    function depositAndDelegate(uint256 assets) external returns (uint256 shares);
}

interface IAccessControlEnumerableSandbox {
    function hasRole(bytes32 role, address account) external view returns (bool);

    function grantRole(bytes32 role, address account) external;

    function renounceRole(bytes32 role, address account) external;

    function getRoleMember(bytes32 role, uint256 index) external view returns (address);
}

interface IFolioV5Sandbox {
    function startRebalance(
        IFolio.TokenRebalanceParams[] calldata tokens,
        IFolio.RebalanceLimits calldata limits,
        uint256 auctionLauncherWindow,
        uint256 ttl
    ) external;

    function openAuction(
        uint256 rebalanceNonce,
        address[] calldata tokens,
        IFolio.WeightRange[] calldata newWeights,
        IFolio.PriceRange[] calldata newPrices,
        IFolio.RebalanceLimits calldata newLimits
    ) external returns (uint256 auctionId);

    function getRebalance()
        external
        view
        returns (
            uint256 nonce,
            IFolio.PriceControl priceControl,
            IFolio.TokenRebalanceParams[] memory tokens,
            IFolio.RebalanceLimits memory limits,
            Folio.RebalanceTimestamps memory timestamps,
            bool bidsEnabled
        );

    function nextAuctionId() external view returns (uint256);
}

abstract contract MainnetAnvilScript is Script {
    uint256 internal constant SANDBOX_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function _requireAnvilRpc() internal {
        vm.rpc("anvil_nodeInfo", "[]");
    }
}

interface IGovernorSandbox is IGovernor {
    function token() external view returns (address);

    function selectorRegistry() external view returns (address);
}

interface IOptimisticGovernorSandbox is IGovernor {
    function proposeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256 proposalId);

    function isOptimistic(uint256 proposalId) external view returns (bool);
}

interface ISelectorRegistryAdminSandbox is ISelectorRegistry_6_0_0 {
    function registerSelectors(IOptimisticSelectorRegistry.SelectorData[] calldata selectorData) external;

    function unregisterSelectors(IOptimisticSelectorRegistry.SelectorData[] calldata selectorData) external;
}

interface IFolioDeployerV5 {
    struct FeeRecipient {
        address recipient;
        uint96 portion;
    }

    enum PriceControl {
        NONE,
        PARTIAL,
        ATOMIC_SWAP
    }

    struct RebalanceControl {
        bool weightControl;
        PriceControl priceControl;
    }

    struct FolioBasicDetails {
        string name;
        string symbol;
        address[] assets;
        uint256[] amounts;
        uint256 initialShares;
    }

    struct FolioAdditionalDetails {
        uint256 auctionLength;
        FeeRecipient[] feeRecipients;
        uint256 tvlFee;
        uint256 mintFee;
        string mandate;
    }

    struct FolioFlags {
        bool trustedFillerEnabled;
        RebalanceControl rebalanceControl;
        bool bidsEnabled;
    }

    struct GovParams {
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumThreshold;
        uint256 timelockDelay;
        address[] guardians;
    }

    struct GovRoles {
        address[] existingBasketManagers;
        address[] auctionLaunchers;
        address[] brandManagers;
    }

    function deployFolio(
        FolioBasicDetails calldata basicDetails,
        FolioAdditionalDetails calldata additionalDetails,
        FolioFlags calldata folioFlags,
        address owner,
        address[] calldata basketManagers,
        address[] calldata auctionLaunchers,
        address[] calldata brandManagers,
        bytes32 deploymentNonce
    ) external returns (address folio, address proxyAdmin);

    function deployGovernedFolio(
        address stToken,
        FolioBasicDetails calldata basicDetails,
        FolioAdditionalDetails calldata additionalDetails,
        FolioFlags calldata folioFlags,
        GovParams calldata ownerGovParams,
        GovParams calldata tradingGovParams,
        GovRoles calldata govRoles,
        bytes32 deploymentNonce
    ) external returns (address folio, address proxyAdmin);
}

/// Broadcast bootstrap. The shell entrypoint performs the RPC safety checks before invoking this script.
contract MainnetAnvilBootstrap is MainnetAnvilScript {
    address internal constant ROLE_REGISTRY_OWNER = 0xe8259842e71f4E44F2F68D6bfbC15EDA56E63064;
    address internal constant DAO_FEE_REGISTRY = 0x0262E3e15cCFD2221b35D05909222f1f5FCdcd80;
    address internal constant VERSION_REGISTRY = 0xA665b273997F70b647B66fa7Ed021287544849dB;
    address internal constant TRUSTED_FILLER_REGISTRY = 0x279ccF56441fC74f1aAC39E7faC165Dec5A88B3A;
    address internal constant OPTIMISTIC_GOVERNOR_DEPLOYER = 0x2ACC45e12776579f40Ae3419764EEf7022763735;
    address internal constant V5_DEPLOYER = 0x4D201a6e5BF975E2CEE9e5cbDfc803C0Ff122073;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 internal privateKey;
    address internal actor;
    string internal stateDir;

    struct FixtureAddresses {
        // "sandbox" (built by this run), "registered" (sandbox mode adopted an existing 6.0.0 registration),
        // or "real" (SANDBOX_V6_DEPLOYER).
        string v6DeployerSource;
        address v6Deployer;
        address spell;
        address v5ControlFolio;
        address v5ControlProxyAdmin;
        address optimisticFolio;
        address optimisticProxyAdmin;
        address optimisticStToken;
        address optimisticGovernor;
        address optimisticTimelock;
        address optimisticSelectorRegistry;
        address legacyFolio;
        address legacyProxyAdmin;
        address legacyStToken;
        address legacyGovernor;
        address legacyTimelock;
        address nativeFolio;
        address nativeProxyAdmin;
        address nativeGovernor;
        address nativeTimelock;
        address nativeSelectorRegistry;
    }

    function run() external {
        _requireAnvilRpc();
        require(block.chainid == 1, "sandbox requires chain id 1");
        privateKey = SANDBOX_PRIVATE_KEY;
        actor = vm.addr(privateKey);
        stateDir = vm.envString("SANDBOX_STATE_DIR");
        // Real mode: use an already-deployed 6.0.0 FolioDeployer (and therefore its optimistic governor deployer)
        // instead of building one. The upgrade spell stays sandbox-built in both modes.
        address realV6Deployer = vm.envOr("SANDBOX_V6_DEPLOYER", address(0));

        FixtureAddresses memory f;
        vm.startBroadcast(privateKey);
        IWETH(WETH).deposit{ value: 40 ether }();
        if (realV6Deployer == address(0)) {
            f.v6Deployer = address(
                new FolioDeployer(
                    DAO_FEE_REGISTRY,
                    VERSION_REGISTRY,
                    TRUSTED_FILLER_REGISTRY,
                    OPTIMISTIC_GOVERNOR_DEPLOYER
                )
            );
        }
        f.spell = address(new UpgradeSpell_6_0_0());
        vm.stopBroadcast();

        if (realV6Deployer != address(0)) {
            f.v6Deployer = _useRealV6Deployer(realV6Deployer);
            f.v6DeployerSource = "real";
        } else if (address(FolioVersionRegistry(VERSION_REGISTRY).deployments(VERSION_6_0_0)) == address(0)) {
            f.v6DeployerSource = "sandbox";
            require(
                IRoleRegistry(address(FolioVersionRegistry(VERSION_REGISTRY).roleRegistry())).isOwner(
                    ROLE_REGISTRY_OWNER
                ),
                "canonical role-registry owner is not authorized"
            );
            vm.startBroadcast(ROLE_REGISTRY_OWNER);
            FolioVersionRegistry(VERSION_REGISTRY).registerVersion(IFolioDeployer(f.v6Deployer));
            vm.stopBroadcast();
        } else {
            // A reused fork may already have a sandbox v6 registration.
            f.v6Deployer = address(FolioVersionRegistry(VERSION_REGISTRY).deployments(VERSION_6_0_0));
            f.v6DeployerSource = "registered";
        }

        vm.startBroadcast(privateKey);
        IERC20(WETH).approve(V5_DEPLOYER, type(uint256).max);
        IERC20(WETH).approve(f.v6Deployer, type(uint256).max);

        if (vm.envOr("SANDBOX_ENABLE_V5_CONTROL", true)) {
            (f.v5ControlFolio, f.v5ControlProxyAdmin) = _deployRawV5("Sandbox v5 Control", "SV5C", "control", true);
        }
        if (vm.envOr("SANDBOX_ENABLE_V5_OPTIMISTIC", true)) {
            _deployOptimisticV5(f);
        }
        if (vm.envOr("SANDBOX_ENABLE_V5_LEGACY", true)) {
            _deployLegacyV5(f);
        }
        if (vm.envOr("SANDBOX_ENABLE_V6_NATIVE", true)) {
            require(f.optimisticStToken != address(0), "v6 native requires optimistic staking vault scenario");
            _deployNativeV6(f);
        }
        vm.stopBroadcast();

        _writeBootstrap(f);
        console2.log("sandbox bootstrap written to", string.concat(stateDir, "/bootstrap.json"));
    }

    /// Validates an existing 6.0.0 FolioDeployer and makes it the registry's 6.0.0 entry. Registration through the
    /// canonical owner simulates the pending production registration. Never adopts a different registered deployer.
    function _useRealV6Deployer(address deployer) internal returns (address) {
        require(
            deployer.code.length != 0,
            "SANDBOX_V6_DEPLOYER has no code on this fork: fork at or after its creation block"
        );
        require(
            keccak256(bytes(FolioDeployer(deployer).version())) == VERSION_6_0_0,
            "SANDBOX_V6_DEPLOYER version() is not 6.0.0"
        );
        require(
            FolioDeployer(deployer).versionRegistry() == VERSION_REGISTRY,
            "SANDBOX_V6_DEPLOYER uses a different version registry"
        );

        FolioVersionRegistry registry = FolioVersionRegistry(VERSION_REGISTRY);
        address registered = address(registry.deployments(VERSION_6_0_0));
        if (registered == address(0)) {
            require(
                IRoleRegistry(address(registry.roleRegistry())).isOwner(ROLE_REGISTRY_OWNER),
                "canonical role-registry owner is not authorized"
            );
            vm.startBroadcast(ROLE_REGISTRY_OWNER);
            registry.registerVersion(IFolioDeployer(deployer));
            vm.stopBroadcast();
        } else {
            require(
                registered == deployer,
                "6.0.0 is registered to a different deployer than SANDBOX_V6_DEPLOYER; reset the fork"
            );
        }
        require(!registry.isDeprecated(VERSION_6_0_0), "6.0.0 is deprecated in the version registry");
        return deployer;
    }

    function _deployRawV5(
        string memory name,
        string memory symbol,
        string memory saltLabel,
        bool actorRoles
    ) internal returns (address folio, address proxyAdmin) {
        address[] memory managers = new address[](actorRoles ? 1 : 0);
        address[] memory launchers = new address[](actorRoles ? 1 : 0);
        if (actorRoles) {
            managers[0] = actor;
            launchers[0] = actor;
        }
        address[] memory empty = new address[](0);
        (folio, proxyAdmin) = IFolioDeployerV5(V5_DEPLOYER).deployFolio(
            _v5Basic(name, symbol),
            _v5Additional(),
            _v5Flags(),
            actor,
            managers,
            launchers,
            empty,
            keccak256(bytes(string.concat("sandbox-v5-", saltLabel)))
        );
    }

    function _deployOptimisticV5(FixtureAddresses memory f) internal {
        (f.optimisticFolio, f.optimisticProxyAdmin) = _deployRawV5(
            "Sandbox v5 Optimistic Upgrade",
            "SV5O",
            "optimistic",
            false
        );

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = START_REBALANCE_5_0_0;
        IOptimisticSelectorRegistry.SelectorData[] memory selectorData = new IOptimisticSelectorRegistry.SelectorData[](
            1
        );
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData({ target: f.optimisticFolio, selectors: selectors });

        IReserveOptimisticGovernorDeployer.BaseDeploymentParams memory baseParams = IReserveOptimisticGovernorDeployer
            .BaseDeploymentParams({
                optimisticParams: IReserveOptimisticGovernor.OptimisticGovernanceParams({
                    vetoDelay: 1 minutes,
                    vetoPeriod: 5 minutes,
                    vetoThreshold: 0.05e18
                }),
                standardParams: IReserveOptimisticGovernor.StandardGovernanceParams({
                    votingDelay: 1 minutes,
                    votingPeriod: 5 minutes,
                    voteExtension: 0,
                    proposalThreshold: 0.01e18,
                    quorumNumerator: 0.01e18
                }),
                selectorData: selectorData,
                optimisticProposers: new address[](0),
                additionalGuardians: new address[](0),
                timelockDelay: 2 seconds,
                proposalThrottleCapacity: 10
            });
        IReserveOptimisticGovernorDeployer.NewStakingVaultParams memory vaultParams = IReserveOptimisticGovernorDeployer
            .NewStakingVaultParams({
                underlying: IERC20Metadata(WETH),
                rewardTokens: new address[](0),
                rewardHalfLife: 1 weeks,
                unstakingDelay: 1 weeks
            });

        (
            f.optimisticStToken,
            f.optimisticGovernor,
            f.optimisticTimelock,
            f.optimisticSelectorRegistry
        ) = IReserveOptimisticGovernorDeployer(OPTIMISTIC_GOVERNOR_DEPLOYER).deployWithNewStakingVault(
            baseParams,
            vaultParams,
            keccak256("sandbox-v5-optimistic-governance")
        );

        IAccessControlEnumerableSandbox(f.optimisticFolio).grantRole(DEFAULT_ADMIN_ROLE, f.optimisticTimelock);
        IAccessControlEnumerableSandbox(f.optimisticFolio).grantRole(REBALANCE_MANAGER, f.optimisticTimelock);
        IAccessControlEnumerableSandbox(f.optimisticFolio).renounceRole(DEFAULT_ADMIN_ROLE, actor);
        FolioProxyAdmin(f.optimisticProxyAdmin).transferOwnership(f.optimisticTimelock);

        IERC20(WETH).approve(f.optimisticStToken, type(uint256).max);
        IStakingVaultSandbox(f.optimisticStToken).depositAndDelegate(8 ether);
    }

    function _deployLegacyV5(FixtureAddresses memory f) internal {
        IFolioDeployerV5.GovParams memory govParams = IFolioDeployerV5.GovParams({
            votingDelay: 1 minutes,
            votingPeriod: 5 minutes,
            proposalThreshold: 0,
            quorumThreshold: 0.01e18,
            timelockDelay: 2 seconds,
            guardians: new address[](0)
        });
        address[] memory managers = new address[](1);
        managers[0] = actor; // Avoid deploying the unused second/trading governor.
        IFolioDeployerV5.GovRoles memory roles = IFolioDeployerV5.GovRoles({
            existingBasketManagers: managers,
            auctionLaunchers: new address[](0),
            brandManagers: new address[](0)
        });

        vm.recordLogs();
        (f.legacyFolio, f.legacyProxyAdmin) = IFolioDeployerV5(V5_DEPLOYER).deployGovernedFolio(
            address(0),
            _v5Basic("Sandbox v5 Legacy Upgrade", "SV5L"),
            _v5Additional(),
            _v5Flags(),
            govParams,
            govParams,
            roles,
            keccak256("sandbox-v5-legacy")
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 governedEvent = keccak256("GovernedFolioDeployed(address,address,address,address,address,address)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == V5_DEPLOYER && logs[i].topics[0] == governedEvent) {
                f.legacyStToken = address(uint160(uint256(logs[i].topics[1])));
                (f.legacyGovernor, f.legacyTimelock, , ) = abi.decode(
                    logs[i].data,
                    (address, address, address, address)
                );
                break;
            }
        }
        require(f.legacyGovernor != address(0), "legacy governance event missing");

        IERC20(f.legacyFolio).approve(f.legacyStToken, type(uint256).max);
        IStakingVaultSandbox(f.legacyStToken).depositAndDelegate(5 ether);
    }

    function _deployNativeV6(FixtureAddresses memory f) internal {
        bytes4[] memory optimisticSelectors = new bytes4[](1);
        optimisticSelectors[0] = START_REBALANCE_6_0_0;
        address[] memory optimisticProposers = new address[](1);
        optimisticProposers[0] = actor;
        IFolioDeployer.GovParams memory params = IFolioDeployer.GovParams({
            optimisticParams: IReserveOptimisticGovernor.OptimisticGovernanceParams({
                vetoDelay: 1 minutes,
                vetoPeriod: 5 minutes,
                vetoThreshold: 0.05e18
            }),
            standardParams: IReserveOptimisticGovernor.StandardGovernanceParams({
                votingDelay: 1 minutes,
                votingPeriod: 5 minutes,
                voteExtension: 0,
                proposalThreshold: 0.01e18,
                quorumNumerator: 0.01e18
            }),
            optimisticSelectors: optimisticSelectors,
            optimisticProposers: optimisticProposers,
            additionalGuardians: new address[](0),
            timelockDelay: 2 seconds,
            proposalThrottleCapacity: 10
        });
        address[] memory managers = new address[](0);
        address[] memory launchers = new address[](1);
        launchers[0] = actor;
        IFolioDeployer.GovRoles memory roles = IFolioDeployer.GovRoles({
            existingBasketManagers: managers,
            auctionLaunchers: launchers,
            brandManagers: new address[](0)
        });

        (Folio folio, address proxyAdmin) = FolioDeployer(f.v6Deployer).deployGovernedFolio(
            f.optimisticStToken,
            _v6Basic(),
            _v6Additional(),
            _v6Flags(),
            params,
            roles,
            keccak256("sandbox-v6-native")
        );
        f.nativeFolio = address(folio);
        f.nativeProxyAdmin = proxyAdmin;
        f.nativeTimelock = IAccessControlEnumerableSandbox(f.nativeFolio).getRoleMember(DEFAULT_ADMIN_ROLE, 0);
        f.nativeGovernor = IAccessControlEnumerableSandbox(f.nativeTimelock).getRoleMember(PROPOSER_ROLE, 0);
        f.nativeSelectorRegistry = IGovernorSandbox(f.nativeGovernor).selectorRegistry();
    }

    function _v5Basic(
        string memory name,
        string memory symbol
    ) internal pure returns (IFolioDeployerV5.FolioBasicDetails memory) {
        address[] memory assets = new address[](1);
        assets[0] = WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        return IFolioDeployerV5.FolioBasicDetails(name, symbol, assets, amounts, 10 ether);
    }

    function _v5Additional() internal view returns (IFolioDeployerV5.FolioAdditionalDetails memory) {
        IFolioDeployerV5.FeeRecipient[] memory recipients = new IFolioDeployerV5.FeeRecipient[](1);
        recipients[0] = IFolioDeployerV5.FeeRecipient(actor, 1e18);
        return IFolioDeployerV5.FolioAdditionalDetails(300, recipients, 0, 0, "Mainnet Anvil SDK fixture");
    }

    function _v5Flags() internal pure returns (IFolioDeployerV5.FolioFlags memory) {
        return
            IFolioDeployerV5.FolioFlags({
                trustedFillerEnabled: false,
                rebalanceControl: IFolioDeployerV5.RebalanceControl(false, IFolioDeployerV5.PriceControl.NONE),
                bidsEnabled: true
            });
    }

    function _v6Basic() internal pure returns (IFolio.FolioBasicDetails memory) {
        address[] memory assets = new address[](1);
        assets[0] = WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        return IFolio.FolioBasicDetails("Sandbox v6 Native", "SV6N", assets, amounts, 10 ether);
    }

    function _v6Additional() internal view returns (IFolio.FolioAdditionalDetails memory) {
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](1);
        recipients[0] = IFolio.FeeRecipient(actor, 1e18);
        return
            IFolio.FolioAdditionalDetails({
                maxAuctionLength: 300,
                feeRecipients: recipients,
                immutableFeeRecipients: new IFolio.FeeRecipient[](0),
                tvlFee: 0,
                mintFee: 0,
                folioFeeForSelf: 0,
                mandate: "Mainnet Anvil SDK fixture"
            });
    }

    function _v6Flags() internal pure returns (IFolio.FolioFlags memory) {
        return
            IFolio.FolioFlags({
                trustedFillerEnabled: false,
                rebalanceControl: IFolio.RebalanceControl(false, IFolio.PriceControl.NONE),
                bidsEnabled: true
            });
    }

    function _writeBootstrap(FixtureAddresses memory f) internal {
        string memory key = "bootstrap";
        vm.serializeUint(key, "schemaVersion", 1);
        vm.serializeUint(key, "forkBlock", vm.envUint("FORK_BLOCK"));
        vm.serializeAddress(key, "actor", actor);
        vm.serializeAddress(key, "weth", WETH);
        vm.serializeAddress(key, "versionRegistry", VERSION_REGISTRY);
        vm.serializeAddress(key, "v5Deployer", V5_DEPLOYER);
        vm.serializeAddress(key, "v6Deployer", f.v6Deployer);
        vm.serializeString(key, "v6DeployerSource", f.v6DeployerSource);
        vm.serializeAddress(key, "v6FolioImplementation", FolioDeployer(f.v6Deployer).folioImplementation());
        vm.serializeAddress(
            key,
            "v6OptimisticGovernorDeployer",
            FolioDeployer(f.v6Deployer).optimisticGovernorDeployer()
        );
        vm.serializeAddress(key, "v5OptimisticGovernorDeployer", OPTIMISTIC_GOVERNOR_DEPLOYER);
        vm.serializeString(key, "spellSource", "sandbox");
        vm.serializeAddress(key, "spell", f.spell);
        vm.serializeAddress(key, "v5ControlFolio", f.v5ControlFolio);
        vm.serializeAddress(key, "v5ControlProxyAdmin", f.v5ControlProxyAdmin);
        vm.serializeAddress(key, "optimisticFolio", f.optimisticFolio);
        vm.serializeAddress(key, "optimisticProxyAdmin", f.optimisticProxyAdmin);
        vm.serializeAddress(key, "optimisticStToken", f.optimisticStToken);
        vm.serializeAddress(key, "optimisticGovernor", f.optimisticGovernor);
        vm.serializeAddress(key, "optimisticTimelock", f.optimisticTimelock);
        vm.serializeAddress(key, "optimisticSelectorRegistry", f.optimisticSelectorRegistry);
        vm.serializeAddress(key, "legacyFolio", f.legacyFolio);
        vm.serializeAddress(key, "legacyProxyAdmin", f.legacyProxyAdmin);
        vm.serializeAddress(key, "legacyStToken", f.legacyStToken);
        vm.serializeAddress(key, "legacyGovernor", f.legacyGovernor);
        vm.serializeAddress(key, "legacyTimelock", f.legacyTimelock);
        vm.serializeAddress(key, "nativeFolio", f.nativeFolio);
        vm.serializeAddress(key, "nativeProxyAdmin", f.nativeProxyAdmin);
        vm.serializeAddress(key, "nativeGovernor", f.nativeGovernor);
        vm.serializeAddress(key, "nativeTimelock", f.nativeTimelock);
        string memory json = vm.serializeAddress(key, "nativeSelectorRegistry", f.nativeSelectorRegistry);
        vm.writeJson(json, string.concat(stateDir, "/bootstrap.json"));
    }
}

/// Staged standard-governance lifecycle. Each invocation broadcasts transactions against persisted Anvil state.
contract MainnetAnvilScenarios is MainnetAnvilScript {
    uint256 internal privateKey;
    string internal stateDir;
    string internal bootstrap;
    string internal proposals;

    function run() external {
        _requireAnvilRpc();
        require(block.chainid == 1, "sandbox requires chain id 1");
        privateKey = SANDBOX_PRIVATE_KEY;
        stateDir = vm.envString("SANDBOX_STATE_DIR");
        bootstrap = vm.readFile(string.concat(stateDir, "/bootstrap.json"));
        string memory stage = vm.envString("SANDBOX_STAGE");

        if (keccak256(bytes(stage)) == keccak256("propose")) _propose();
        else if (keccak256(bytes(stage)) == keccak256("vote")) _vote();
        else if (keccak256(bytes(stage)) == keccak256("queue")) _queue();
        else if (keccak256(bytes(stage)) == keccak256("execute")) _execute();
        else revert("unknown SANDBOX_STAGE");
    }

    function _propose() internal {
        address spell = _address(".spell");
        uint256 optimisticId;
        uint256 legacyId;
        vm.startBroadcast(privateKey);
        address optimisticGovernor = _address(".optimisticGovernor");
        if (optimisticGovernor != address(0)) {
            (address[] memory targets, uint256[] memory values, bytes[] memory calls) = _optimisticActions(spell);
            optimisticId = IGovernor(optimisticGovernor).propose(targets, values, calls, _optimisticDescription());
        }
        address legacyGovernor = _address(".legacyGovernor");
        if (legacyGovernor != address(0)) {
            (address[] memory targets, uint256[] memory values, bytes[] memory calls) = _legacyActions(spell);
            legacyId = IGovernor(legacyGovernor).propose(targets, values, calls, _legacyDescription());
        }
        vm.stopBroadcast();

        string memory key = "proposals";
        vm.serializeString(key, "optimisticProposalId", vm.toString(optimisticId));
        string memory json = vm.serializeString(key, "legacyProposalId", vm.toString(legacyId));
        vm.writeJson(json, string.concat(stateDir, "/proposals.json"));
    }

    function _vote() internal {
        _loadProposals();
        vm.startBroadcast(privateKey);
        uint256 id = _proposalId(".optimisticProposalId");
        IGovernor governor = IGovernor(_address(".optimisticGovernor"));
        if (
            id != 0 &&
            governor.state(id) == IGovernor.ProposalState.Active &&
            !governor.hasVoted(id, vm.addr(privateKey))
        ) {
            governor.castVote(id, 1);
        }
        id = _proposalId(".legacyProposalId");
        governor = IGovernor(_address(".legacyGovernor"));
        if (
            id != 0 &&
            governor.state(id) == IGovernor.ProposalState.Active &&
            !governor.hasVoted(id, vm.addr(privateKey))
        ) {
            governor.castVote(id, 1);
        }
        vm.stopBroadcast();
    }

    function _queue() internal {
        _loadProposals();
        address spell = _address(".spell");
        vm.startBroadcast(privateKey);
        uint256 id = _proposalId(".optimisticProposalId");
        if (id != 0 && IGovernor(_address(".optimisticGovernor")).state(id) == IGovernor.ProposalState.Succeeded) {
            (address[] memory targets, uint256[] memory values, bytes[] memory calls) = _optimisticActions(spell);
            IGovernor(_address(".optimisticGovernor")).queue(
                targets,
                values,
                calls,
                keccak256(bytes(_optimisticDescription()))
            );
        }
        id = _proposalId(".legacyProposalId");
        if (id != 0 && IGovernor(_address(".legacyGovernor")).state(id) == IGovernor.ProposalState.Succeeded) {
            (address[] memory targets, uint256[] memory values, bytes[] memory calls) = _legacyActions(spell);
            IGovernor(_address(".legacyGovernor")).queue(
                targets,
                values,
                calls,
                keccak256(bytes(_legacyDescription()))
            );
        }
        vm.stopBroadcast();
    }

    function _execute() internal {
        _loadProposals();
        address spell = _address(".spell");
        vm.startBroadcast(privateKey);
        uint256 id = _proposalId(".optimisticProposalId");
        if (id != 0 && IGovernor(_address(".optimisticGovernor")).state(id) == IGovernor.ProposalState.Queued) {
            (address[] memory targets, uint256[] memory values, bytes[] memory calls) = _optimisticActions(spell);
            IGovernor(_address(".optimisticGovernor")).execute(
                targets,
                values,
                calls,
                keccak256(bytes(_optimisticDescription()))
            );
        }
        id = _proposalId(".legacyProposalId");
        if (id != 0 && IGovernor(_address(".legacyGovernor")).state(id) == IGovernor.ProposalState.Queued) {
            (address[] memory targets, uint256[] memory values, bytes[] memory calls) = _legacyActions(spell);
            IGovernor(_address(".legacyGovernor")).execute(
                targets,
                values,
                calls,
                keccak256(bytes(_legacyDescription()))
            );
        }
        vm.stopBroadcast();
    }

    function _optimisticActions(
        address spell
    ) internal view returns (address[] memory targets, uint256[] memory values, bytes[] memory calls) {
        address folio = _address(".optimisticFolio");
        address proxyAdmin = _address(".optimisticProxyAdmin");
        ISelectorRegistryAdminSandbox registry = ISelectorRegistryAdminSandbox(_address(".optimisticSelectorRegistry"));
        IOptimisticSelectorRegistry.SelectorData[] memory data = new IOptimisticSelectorRegistry.SelectorData[](1);
        bytes4[] memory selectors = new bytes4[](1);
        data[0] = IOptimisticSelectorRegistry.SelectorData({ target: folio, selectors: selectors });

        targets = new address[](4);
        values = new uint256[](4);
        calls = new bytes[](4);
        targets[0] = address(registry);
        targets[1] = address(registry);
        targets[2] = proxyAdmin;
        targets[3] = spell;
        selectors[0] = START_REBALANCE_6_0_0;
        calls[0] = abi.encodeCall(ISelectorRegistryAdminSandbox.registerSelectors, (data));
        selectors[0] = START_REBALANCE_5_0_0;
        calls[1] = abi.encodeCall(ISelectorRegistryAdminSandbox.unregisterSelectors, (data));
        calls[2] = abi.encodeWithSignature("transferOwnership(address)", spell);
        calls[3] = abi.encodeCall(
            UpgradeSpell_6_0_0.cast,
            (Folio(folio), FolioProxyAdmin(proxyAdmin), ISelectorRegistry_6_0_0(address(registry)))
        );
    }

    function _legacyActions(
        address spell
    ) internal view returns (address[] memory targets, uint256[] memory values, bytes[] memory calls) {
        address folio = _address(".legacyFolio");
        address proxyAdmin = _address(".legacyProxyAdmin");
        targets = new address[](2);
        values = new uint256[](2);
        calls = new bytes[](2);
        targets[0] = proxyAdmin;
        targets[1] = spell;
        calls[0] = abi.encodeWithSignature("transferOwnership(address)", spell);
        calls[1] = abi.encodeCall(
            UpgradeSpell_6_0_0.cast,
            (Folio(folio), FolioProxyAdmin(proxyAdmin), ISelectorRegistry_6_0_0(address(0)))
        );
    }

    function _optimisticDescription() internal pure returns (string memory) {
        return "Sandbox exact standard-governance optimistic v5 to v6 upgrade";
    }

    function _legacyDescription() internal pure returns (string memory) {
        return "Sandbox exact standard-governance legacy v5 to v6 upgrade";
    }

    function _address(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(bootstrap, key);
    }

    function _loadProposals() internal {
        proposals = vm.readFile(string.concat(stateDir, "/proposals.json"));
    }

    function _proposalId(string memory key) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(proposals, key));
    }
}

/// Append-only v5/v6 rebalance and auction flows for SDK and subgraph parity tests.
contract MainnetAnvilExecutionScenarios is MainnetAnvilScript {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 internal constant AUCTION_LENGTH = 300;
    uint256 internal constant LAUNCHER_WINDOW = 1 hours;
    uint256 internal constant REBALANCE_TTL = 1 days;

    uint256 internal privateKey;
    address internal actor;
    string internal stateDir;
    string internal bootstrap;
    string internal executionProposal;

    function run() external {
        _requireAnvilRpc();
        require(block.chainid == 1, "sandbox requires chain id 1");
        privateKey = SANDBOX_PRIVATE_KEY;
        actor = vm.addr(privateKey);
        stateDir = vm.envString("SANDBOX_STATE_DIR");
        bootstrap = vm.readFile(string.concat(stateDir, "/bootstrap.json"));
        string memory stage = vm.envString("SANDBOX_EXECUTION_STAGE");

        if (keccak256(bytes(stage)) == keccak256("grant-v5-roles")) _grantV5Roles();
        else if (keccak256(bytes(stage)) == keccak256("propose-v6-authority")) _proposeV6Authority();
        else if (keccak256(bytes(stage)) == keccak256("vote-v6-authority")) _voteV6Authority();
        else if (keccak256(bytes(stage)) == keccak256("queue-v6-authority")) _queueV6Authority();
        else if (keccak256(bytes(stage)) == keccak256("execute-v6-authority")) _executeV6Authority();
        else if (keccak256(bytes(stage)) == keccak256("propose-v6-rebalance")) _proposeV6Rebalance();
        else if (keccak256(bytes(stage)) == keccak256("execute-v6-rebalance")) _executeV6Rebalance();
        else if (keccak256(bytes(stage)) == keccak256("start-v5")) _startV5();
        else if (keccak256(bytes(stage)) == keccak256("open-v5")) _openV5();
        else if (keccak256(bytes(stage)) == keccak256("open-v6")) _openV6();
        else if (keccak256(bytes(stage)) == keccak256("start-legacy-v6")) _startLegacyV6();
        else if (keccak256(bytes(stage)) == keccak256("open-legacy-v6")) _openLegacyV6();
        else revert("unknown SANDBOX_EXECUTION_STAGE");
    }

    function _grantV5Roles() internal {
        IAccessControlEnumerableSandbox folio = IAccessControlEnumerableSandbox(_address(".v5ControlFolio"));
        vm.startBroadcast(privateKey);
        if (!folio.hasRole(REBALANCE_MANAGER, actor)) folio.grantRole(REBALANCE_MANAGER, actor);
        if (!folio.hasRole(AUCTION_LAUNCHER, actor)) folio.grantRole(AUCTION_LAUNCHER, actor);
        vm.stopBroadcast();
    }

    function _proposeV6Authority() internal {
        IAccessControlEnumerableSandbox folio = IAccessControlEnumerableSandbox(_address(".nativeFolio"));
        IAccessControlEnumerableSandbox timelock = IAccessControlEnumerableSandbox(_address(".nativeTimelock"));
        uint256 proposalId;
        string memory description;
        if (!timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, actor) || !folio.hasRole(AUCTION_LAUNCHER, actor)) {
            (address[] memory targets, uint256[] memory values, bytes[] memory calls) = _v6AuthorityActions();
            description = string.concat("Sandbox native-v6 authority at ", vm.toString(block.timestamp));
            vm.startBroadcast(privateKey);
            proposalId = IGovernor(_address(".nativeGovernor")).propose(targets, values, calls, description);
            vm.stopBroadcast();
        }

        string memory json = vm.serializeString("executionProposal", "authorityProposalId", vm.toString(proposalId));
        json = vm.serializeString("executionProposal", "authorityDescription", description);
        vm.writeJson(json, string.concat(stateDir, "/execution-proposal.json"));
    }

    function _voteV6Authority() internal {
        uint256 id = _executionProposalId(".authorityProposalId");
        if (id == 0) return;
        IGovernor governor = IGovernor(_address(".nativeGovernor"));
        if (governor.state(id) != IGovernor.ProposalState.Active || governor.hasVoted(id, actor)) return;
        vm.startBroadcast(privateKey);
        governor.castVote(id, 1);
        vm.stopBroadcast();
    }

    function _queueV6Authority() internal {
        uint256 id = _executionProposalId(".authorityProposalId");
        if (id == 0) return;
        IGovernor governor = IGovernor(_address(".nativeGovernor"));
        if (governor.state(id) != IGovernor.ProposalState.Succeeded) return;
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) = _v6AuthorityActions();
        vm.startBroadcast(privateKey);
        governor.queue(targets, values, calls, keccak256(bytes(_executionProposalString(".authorityDescription"))));
        vm.stopBroadcast();
    }

    function _executeV6Authority() internal {
        uint256 id = _executionProposalId(".authorityProposalId");
        if (id == 0) return;
        IGovernor governor = IGovernor(_address(".nativeGovernor"));
        if (governor.state(id) != IGovernor.ProposalState.Queued) return;
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) = _v6AuthorityActions();
        vm.startBroadcast(privateKey);
        governor.execute(targets, values, calls, keccak256(bytes(_executionProposalString(".authorityDescription"))));
        vm.stopBroadcast();
    }

    function _proposeV6Rebalance() internal {
        Folio folio = Folio(_address(".nativeFolio"));
        (uint256 currentNonce, , , , , ) = folio.getRebalance();
        if (currentNonce != 0) return;
        uint256 deadline = block.timestamp + 1 hours;
        string memory description = string.concat(
            "Sandbox native-v6 optimistic rebalance at ",
            vm.toString(block.timestamp)
        );
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) = _v6RebalanceAction(
            currentNonce + 1,
            deadline
        );
        vm.startBroadcast(privateKey);
        uint256 proposalId = IOptimisticGovernorSandbox(_address(".nativeGovernor")).proposeOptimistic(
            targets,
            values,
            calls,
            description
        );
        vm.stopBroadcast();

        uint256 authorityProposalId = _executionProposalId(".authorityProposalId");
        string memory json = vm.serializeString(
            "executionProposal",
            "authorityProposalId",
            vm.toString(authorityProposalId)
        );
        json = vm.serializeString(
            "executionProposal",
            "authorityDescription",
            _executionProposalString(".authorityDescription")
        );
        json = vm.serializeString("executionProposal", "rebalanceProposalId", vm.toString(proposalId));
        json = vm.serializeString("executionProposal", "rebalanceDescription", description);
        json = vm.serializeUint("executionProposal", "rebalanceDeadline", deadline);
        json = vm.serializeUint("executionProposal", "rebalanceNonce", currentNonce + 1);
        vm.writeJson(json, string.concat(stateDir, "/execution-proposal.json"));
    }

    function _executeV6Rebalance() internal {
        uint256 id = _executionProposalId(".rebalanceProposalId");
        if (id == 0) return;
        IOptimisticGovernorSandbox governor = IOptimisticGovernorSandbox(_address(".nativeGovernor"));
        if (governor.state(id) != IGovernor.ProposalState.Succeeded) return;
        uint256 deadline = _executionProposalId(".rebalanceDeadline");
        uint256 nonce = _executionProposalId(".rebalanceNonce");
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) = _v6RebalanceAction(nonce, deadline);
        vm.startBroadcast(privateKey);
        governor.execute(targets, values, calls, keccak256(bytes(_executionProposalString(".rebalanceDescription"))));
        vm.stopBroadcast();
    }

    function _startV5() internal {
        IFolioV5Sandbox folio = IFolioV5Sandbox(_address(".v5ControlFolio"));
        (uint256 nonce, , , , , ) = folio.getRebalance();
        if (nonce != 0) return;
        (IFolio.TokenRebalanceParams[] memory tokens, IFolio.RebalanceLimits memory limits) = _rebalanceParams();
        vm.startBroadcast(privateKey);
        folio.startRebalance(tokens, limits, LAUNCHER_WINDOW, REBALANCE_TTL);
        vm.stopBroadcast();
    }

    function _openV5() internal {
        IFolioV5Sandbox folio = IFolioV5Sandbox(_address(".v5ControlFolio"));
        if (folio.nextAuctionId() != 0) return;
        (IFolio.TokenRebalanceParams[] memory params, IFolio.RebalanceLimits memory limits) = _rebalanceParams();
        (
            address[] memory tokens,
            IFolio.WeightRange[] memory weights,
            IFolio.PriceRange[] memory prices
        ) = _auctionParams(params);
        (uint256 nonce, , , , , ) = folio.getRebalance();
        require(nonce != 0, "v5 rebalance missing");
        vm.startBroadcast(privateKey);
        folio.openAuction(nonce, tokens, weights, prices, limits);
        vm.stopBroadcast();
    }

    function _openV6() internal {
        Folio folio = Folio(_address(".nativeFolio"));
        if (folio.nextAuctionId() != 0) return;
        (IFolio.TokenRebalanceParams[] memory params, IFolio.RebalanceLimits memory limits) = _rebalanceParams();
        (
            address[] memory tokens,
            IFolio.WeightRange[] memory weights,
            IFolio.PriceRange[] memory prices
        ) = _auctionParams(params);
        (uint256 nonce, , , , , ) = folio.getRebalance();
        require(nonce != 0, "v6 rebalance missing");
        vm.startBroadcast(privateKey);
        folio.openAuction(nonce, tokens, weights, prices, limits, AUCTION_LENGTH);
        vm.stopBroadcast();
    }

    /// Rebalance after upgrade: the legacy Folio keeps the actor as its direct REBALANCE_MANAGER through the spell.
    /// No launcher window, so the auction below goes through the permissionless openAuctionUnrestricted path.
    function _startLegacyV6() internal {
        Folio folio = Folio(_address(".legacyFolio"));
        require(keccak256(bytes(folio.version())) == keccak256("6.0.0"), "legacy folio is not upgraded");
        (uint256 nonce, , , , , ) = folio.getRebalance();
        if (nonce != 0) return;
        (IFolio.TokenRebalanceParams[] memory tokens, IFolio.RebalanceLimits memory limits) = _rebalanceParams();
        vm.startBroadcast(privateKey);
        folio.startRebalance(nonce + 1, tokens, limits, 0, REBALANCE_TTL, block.timestamp + 1 hours);
        vm.stopBroadcast();
    }

    function _openLegacyV6() internal {
        Folio folio = Folio(_address(".legacyFolio"));
        if (folio.nextAuctionId() != 0) return;
        (uint256 nonce, , , , , ) = folio.getRebalance();
        require(nonce != 0, "legacy v6 rebalance missing");
        vm.startBroadcast(privateKey);
        folio.openAuctionUnrestricted(nonce);
        vm.stopBroadcast();
    }

    function _v6AuthorityActions()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calls)
    {
        address folio = _address(".nativeFolio");
        address timelock = _address(".nativeTimelock");
        targets = new address[](2);
        values = new uint256[](2);
        calls = new bytes[](2);
        targets[0] = timelock;
        targets[1] = folio;
        calls[0] = abi.encodeCall(IAccessControlEnumerableSandbox.grantRole, (OPTIMISTIC_PROPOSER_ROLE, actor));
        calls[1] = abi.encodeCall(IAccessControlEnumerableSandbox.grantRole, (AUCTION_LAUNCHER, actor));
    }

    function _v6RebalanceAction(
        uint256 nonce,
        uint256 deadline
    ) internal view returns (address[] memory targets, uint256[] memory values, bytes[] memory calls) {
        (IFolio.TokenRebalanceParams[] memory tokens, IFolio.RebalanceLimits memory limits) = _rebalanceParams();
        targets = new address[](1);
        values = new uint256[](1);
        calls = new bytes[](1);
        targets[0] = _address(".nativeFolio");
        calls[0] = abi.encodeCall(
            Folio.startRebalance,
            (nonce, tokens, limits, LAUNCHER_WINDOW, REBALANCE_TTL, deadline)
        );
    }

    function _rebalanceParams()
        internal
        pure
        returns (IFolio.TokenRebalanceParams[] memory tokens, IFolio.RebalanceLimits memory limits)
    {
        tokens = new IFolio.TokenRebalanceParams[](2);
        IFolio.WeightRange memory sell = IFolio.WeightRange({ low: 0, spot: 0, high: 0 });
        IFolio.WeightRange memory buy = IFolio.WeightRange({ low: MAX_WEIGHT, spot: MAX_WEIGHT, high: MAX_WEIGHT });
        tokens[0] = IFolio.TokenRebalanceParams({
            token: WETH,
            weight: sell,
            price: IFolio.PriceRange({ low: 1e12, high: 3e12 }),
            maxAuctionSize: type(uint256).max,
            inRebalance: true
        });
        tokens[1] = IFolio.TokenRebalanceParams({
            token: USDC,
            weight: buy,
            price: IFolio.PriceRange({ low: 9e20, high: 11e20 }),
            maxAuctionSize: type(uint256).max,
            inRebalance: true
        });
        limits = IFolio.RebalanceLimits({ low: 1, spot: 1e18, high: 1e27 });
    }

    function _auctionParams(
        IFolio.TokenRebalanceParams[] memory params
    )
        internal
        pure
        returns (address[] memory tokens, IFolio.WeightRange[] memory weights, IFolio.PriceRange[] memory prices)
    {
        tokens = new address[](params.length);
        weights = new IFolio.WeightRange[](params.length);
        prices = new IFolio.PriceRange[](params.length);
        for (uint256 i; i < params.length; ++i) {
            tokens[i] = params[i].token;
            weights[i] = params[i].weight;
            prices[i] = params[i].price;
        }
    }

    function _executionProposalId(string memory key) internal returns (uint256) {
        executionProposal = vm.readFile(string.concat(stateDir, "/execution-proposal.json"));
        return vm.parseUint(vm.parseJsonString(executionProposal, key));
    }

    function _executionProposalString(string memory key) internal returns (string memory) {
        executionProposal = vm.readFile(string.concat(stateDir, "/execution-proposal.json"));
        return vm.parseJsonString(executionProposal, key);
    }

    function _address(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(bootstrap, key);
    }
}
