// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../base/BaseTest.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { GovernanceSpell_31_03_2025 } from "@spells/31-03-2025/GovernanceSpell_31_03_2025.sol";

import { Folio } from "@src/Folio.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import { GovernanceDeployer } from "@deployer/GovernanceDeployer.sol";

abstract contract GovernanceSpell_31_03_2025_Test is BaseTest {
    struct Config {
        Folio folio;
        FolioProxyAdmin proxyAdmin;
        FolioGovernor ownerGovernor;
        FolioGovernor tradingGovernor;
        FolioGovernor stakingVaultGovernor;
        address[] guardians;
    }

    Config[] public CONFIGS;

    // ====

    GovernanceSpell_31_03_2025 public spell;

    FolioGovernor public ownerGovernor;
    FolioGovernor public tradingGovernor;
    TimelockController public ownerTimelock;
    TimelockController public tradingTimelock;

    StakingVault public stakingVault;
    FolioGovernor public stakingVaultGovernor;
    TimelockController public stakingVaultTimelock;

    function _setUp() public virtual override {
        super._setUp();

        governorImplementation = address(new FolioGovernor());
        timelockImplementation = address(new TimelockControllerUpgradeable());
        governanceDeployer = new GovernanceDeployer(governorImplementation, timelockImplementation);
        // TODO replace with real governanceDeployer

        spell = new GovernanceSpell_31_03_2025(governanceDeployer);
    }

    function _setUp(uint256 i) internal {
        console2.log("index ", i, "/", CONFIGS.length - 1);

        folio = CONFIGS[i].folio;
        proxyAdmin = CONFIGS[i].proxyAdmin;
        ownerGovernor = CONFIGS[i].ownerGovernor;
        tradingGovernor = CONFIGS[i].tradingGovernor;
        ownerTimelock = TimelockController(payable(folio.getRoleMember(folio.DEFAULT_ADMIN_ROLE(), 0)));
        tradingTimelock = TimelockController(payable(folio.getRoleMember(folio.AUCTION_APPROVER(), 0)));
        assert(ownerGovernor.timelock() == address(ownerTimelock));
        assert(tradingGovernor.timelock() == address(tradingTimelock));

        stakingVault = StakingVault(address(ownerGovernor.token()));
        assert(stakingVault == StakingVault(address(tradingGovernor.token())));
        stakingVaultGovernor = CONFIGS[i].stakingVaultGovernor;
        stakingVaultTimelock = TimelockController(payable(stakingVault.owner()));
    }

    function test_upgradeStakingVaultGovernance_fork() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            _setUp(i);

            vm.prank(address(stakingVaultTimelock));
            stakingVault.transferOwnership(address(spell));

            FolioGovernor newStakingVaultGovernor = FolioGovernor(
                payable(
                    spell.upgradeStakingVaultGovernance(
                        stakingVault,
                        stakingVaultGovernor,
                        CONFIGS[i].guardians,
                        bytes32(i)
                    )
                )
            );

            assertEq(newStakingVaultGovernor.votingDelay(), stakingVaultGovernor.votingDelay());
            assertEq(newStakingVaultGovernor.votingPeriod(), stakingVaultGovernor.votingPeriod());
            assertEq(newStakingVaultGovernor.quorumNumerator(), stakingVaultGovernor.quorumNumerator() * 1e16);
            assertEq(newStakingVaultGovernor.quorumDenominator(), stakingVaultGovernor.quorumDenominator() * 1e16);
            assertApproxEqAbs(
                newStakingVaultGovernor.proposalThreshold(),
                stakingVaultGovernor.proposalThreshold() / 100,
                1,
                "proposal threshold changed"
            );
            assertEq(
                TimelockController(payable(newStakingVaultGovernor.timelock())).getMinDelay(),
                TimelockController(payable(stakingVaultGovernor.timelock())).getMinDelay()
            );
        }
    }

    function test_upgradeFolioGovernance_fork() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            _setUp(i);

            vm.startPrank(address(ownerTimelock));
            proxyAdmin.transferOwnership(address(spell));
            folio.grantRole(DEFAULT_ADMIN_ROLE, address(spell));

            (address _newOwnerGovernor, address _newTradingGovernor) = spell.upgradeFolioGovernance(
                CONFIGS[i].folio,
                CONFIGS[i].proxyAdmin,
                CONFIGS[i].ownerGovernor,
                CONFIGS[i].tradingGovernor,
                CONFIGS[i].guardians,
                CONFIGS[i].guardians,
                bytes32(i)
            );
            vm.stopPrank();

            FolioGovernor newOwnerGovernor = FolioGovernor(payable(_newOwnerGovernor));
            FolioGovernor newTradingGovernor = FolioGovernor(payable(_newTradingGovernor));

            assertEq(newOwnerGovernor.votingDelay(), ownerGovernor.votingDelay());
            assertEq(newOwnerGovernor.votingPeriod(), ownerGovernor.votingPeriod());
            assertEq(newOwnerGovernor.quorumNumerator(), ownerGovernor.quorumNumerator() * 1e16);
            assertEq(newOwnerGovernor.quorumDenominator(), ownerGovernor.quorumDenominator() * 1e16);
            assertApproxEqAbs(
                FolioGovernor(payable(newOwnerGovernor)).proposalThreshold(),
                ownerGovernor.proposalThreshold() / 100,
                1,
                "owner proposal threshold changed"
            );
            assertEq(
                TimelockController(payable(newOwnerGovernor.timelock())).getMinDelay(),
                TimelockController(payable(ownerGovernor.timelock())).getMinDelay()
            );

            assertEq(newTradingGovernor.votingDelay(), tradingGovernor.votingDelay());
            assertEq(newTradingGovernor.votingPeriod(), tradingGovernor.votingPeriod());
            assertEq(newTradingGovernor.quorumNumerator(), tradingGovernor.quorumNumerator() * 1e16);
            assertEq(newTradingGovernor.quorumDenominator(), tradingGovernor.quorumDenominator() * 1e16);
            assertApproxEqAbs(
                FolioGovernor(payable(newTradingGovernor)).proposalThreshold(),
                tradingGovernor.proposalThreshold() / 100,
                1,
                "trading proposal threshold changed"
            );
            assertEq(
                TimelockController(payable(newTradingGovernor.timelock())).getMinDelay(),
                TimelockController(payable(tradingGovernor.timelock())).getMinDelay()
            );
        }
    }
}
