// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { OPTIMISTIC_PROPOSER_ROLE, PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE } from "@reserve-protocol/reserve-governor/contracts/utils/Constants.sol";
import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";
import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernorDeployer } from "@reserve-protocol/reserve-governor/contracts/interfaces/IDeployer.sol";

import { MAX_AUCTION_LENGTH, MAX_TVL_FEE, MAX_MINT_FEE } from "@utils/Constants.sol";
import { IFolioDeployer } from "@deployer/FolioDeployer.sol";
import { AUCTION_LAUNCHER, BRAND_MANAGER, REBALANCE_MANAGER, DEFAULT_ADMIN_ROLE } from "@utils/Constants.sol";
import "./base/BaseTest.sol";

/// @dev Extended interfaces for testing - includes methods not in the base interfaces
interface IStakingVaultTest is IERC5805, IERC4626, IAccessControl {}

interface IStakingVaultRewards is IStakingVaultTest {
    function getAllRewardTokens() external view returns (address[] memory);
}

interface IGovernorTest is IGovernor {
    function optimisticParams() external view returns (IReserveOptimisticGovernor.OptimisticGovernanceParams memory);
    function getProposalThrottleCapacity() external view returns (uint256);
    function quorumNumerator() external view returns (uint256);
    function quorumDenominator() external view returns (uint256);
}

interface ITimelockTest is IAccessControl {
    function getMinDelay() external view returns (uint256);
}

contract FolioDeployerTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;
    uint256 internal constant MAX_TVL_FEE_PER_SECOND = 3340960028; // D18{1/s} 10% annually, per second

    IStakingVaultTest stToken;
    IGovernorTest governor;
    ITimelockTest timelock;
    IOptimisticSelectorRegistry selectorRegistry;

    function test_constructor() public view {
        assertEq(address(folioDeployer.daoFeeRegistry()), address(daoFeeRegistry));
        assertNotEq(address(folioDeployer.folioImplementation()), address(0));
        assertEq(folioDeployer.optimisticGovernorDeployer(), address(optimisticGovernanceDeployer));
    }

    function test_createFolio() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);
        vm.startSnapshotGas("deployFolio()");
        (folio, proxyAdmin) = createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_TVL_FEE,
            MAX_MINT_FEE,
            owner,
            dao,
            auctionLauncher
        );
        vm.stopSnapshotGas();
        vm.stopPrank();
        assertEq(folio.name(), "Test Folio", "wrong name");
        assertEq(folio.symbol(), "TFOLIO", "wrong symbol");
        assertEq(folio.decimals(), 18, "wrong decimals");
        assertEq(folio.maxAuctionLength(), MAX_AUCTION_LENGTH, "wrong auction length");
        assertEq(folio.totalSupply(), 1e18 * 10000, "wrong total supply");
        assertEq(folio.balanceOf(owner), 1e18 * 10000, "wrong owner balance");
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 2, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K, "wrong folio usdc balance");
        assertEq(DAI.balanceOf(address(folio)), D18_TOKEN_10K, "wrong folio dai balance");
        assertEq(folio.tvlFee(), MAX_TVL_FEE_PER_SECOND, "wrong tvl fee");
        (address r1, uint256 bps1) = folio.feeRecipients(0);
        assertEq(r1, owner, "wrong first recipient");
        assertEq(bps1, 0.9e18, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.feeRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 0.1e18, "wrong second recipient bps");

        assertTrue(folio.hasRole(folio.DEFAULT_ADMIN_ROLE(), owner), "wrong admin role");

        assertTrue(folio.hasRole(REBALANCE_MANAGER, dao), "wrong basket manager role");

        assertTrue(folio.hasRole(AUCTION_LAUNCHER, auctionLauncher), "wrong auction launcher role");

        assertTrue(folio.hasRole(BRAND_MANAGER, owner), "wrong brand manager role");
    }

    function test_cannotCreateFolioWithLengthMismatch() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = D6_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);
        vm.expectRevert(IFolioDeployer.FolioDeployer__LengthMismatch.selector);

        createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_TVL_FEE,
            0,
            owner,
            dao,
            auctionLauncher
        );
        vm.stopPrank();
    }

    function test_cannotCreateFolioWithNoAssets() public {
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        vm.startPrank(owner);
        vm.expectRevert(IFolio.Folio__EmptyAssets.selector);
        createFolio(tokens, amounts, 1, MAX_AUCTION_LENGTH, recipients, MAX_TVL_FEE, 0, owner, dao, auctionLauncher);
        vm.stopPrank();
    }

    function test_cannotCreateFolioWithInvalidAsset() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(0); // invalid
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        vm.expectRevert(); // when trying to transfer tokens
        createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_TVL_FEE,
            0,
            owner,
            dao,
            auctionLauncher
        );
        vm.stopPrank();
    }

    function test_cannotCreateFolioWithZeroAmount() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = 0;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IFolio.Folio__InvalidAssetAmount.selector, address(DAI)));
        createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_TVL_FEE,
            0,
            owner,
            dao,
            auctionLauncher
        );
        vm.stopPrank();
    }

    function test_cannotCreateFolioWithNoApprovalOrBalance() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = D6_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        vm.startPrank(owner);
        vm.expectRevert(); // no approval
        createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_AUCTION_LENGTH,
            recipients,
            100,
            0,
            owner,
            dao,
            auctionLauncher
        );
        vm.stopPrank();

        // with approval but no balance
        vm.startPrank(user1);
        USDC.transfer(owner, USDC.balanceOf(user1));
        USDC.approve(address(folioDeployer), type(uint256).max);
        vm.expectRevert(); // no balance
        createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_TVL_FEE,
            0,
            owner,
            dao,
            auctionLauncher
        );
        vm.stopPrank();
    }

    function test_cannotCreateFolioWithInvalidAuctionLength() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = D6_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);

        vm.expectRevert(IFolio.Folio__InvalidAuctionLength.selector); // below min
        createFolio(tokens, amounts, INITIAL_SUPPLY, 1, recipients, MAX_TVL_FEE, 0, owner, dao, auctionLauncher);

        vm.expectRevert(IFolio.Folio__InvalidAuctionLength.selector); // above max
        createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_AUCTION_LENGTH + 1,
            recipients,
            MAX_TVL_FEE,
            0,
            owner,
            dao,
            auctionLauncher
        );

        vm.stopPrank();
    }

    function test_createGovernedFolio() public {
        address[] memory guardians = new address[](1);
        guardians[0] = user1;

        address[] memory auctionLaunchers = new address[](1);
        auctionLaunchers[0] = auctionLauncher;

        IFolioDeployer.GovRoles memory govRoles = IFolioDeployer.GovRoles(
            new address[](0),
            auctionLaunchers,
            new address[](0)
        );
        address existingStToken = _deployExistingStToken(guardians);

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);

        {
            // stack-too-deep
            address _folio;
            address _governor;
            address _timelock;

            vm.startSnapshotGas("deployGovernedFolio");
            vm.recordLogs();
            (_folio, ) = folioDeployer.deployGovernedFolio(
                existingStToken,
                _basicDetails(),
                _additionalDetails(),
                _flags(),
                _govParams(guardians, _selectorAllowlist(Folio.startRebalance.selector)),
                govRoles,
                bytes32(0)
            );
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(_countGovernanceSystemDeployments(logs), 1, "wrong governance deployment count");
            (_governor, _timelock) = _assertGovernedFolioEvent(logs, existingStToken, _folio);
            selectorRegistry = IOptimisticSelectorRegistry(_governanceSelectorRegistry(logs, _governor));
            assertTrue(selectorRegistry.isAllowed(_folio, Folio.startRebalance.selector), "wrong selector registry");
            assertFalse(selectorRegistry.isAllowed(_folio, Folio.openAuction.selector), "wrong selector registry");
            vm.stopSnapshotGas("deployGovernedFolio()");
            vm.stopPrank();
            stToken = IStakingVaultTest(existingStToken);
            governor = IGovernorTest(_governor);
            timelock = ITimelockTest(_timelock);
            folio = Folio(_folio);
        }

        // Check Folio

        assertEq(folio.symbol(), "TFOLIO", "wrong symbol");
        assertEq(folio.decimals(), 18, "wrong decimals");
        assertEq(folio.maxAuctionLength(), MAX_AUCTION_LENGTH, "wrong auction length");
        assertEq(folio.totalSupply(), 1e18 * 10000, "wrong total supply");
        assertEq(folio.balanceOf(owner), 1e18 * 10000, "wrong owner balance");
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 2, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K, "wrong folio usdc balance");
        assertEq(DAI.balanceOf(address(folio)), D18_TOKEN_10K, "wrong folio dai balance");
        assertEq(folio.tvlFee(), MAX_TVL_FEE_PER_SECOND, "wrong tvl fee");
        (address r1, uint256 bps1) = folio.feeRecipients(0);
        assertEq(r1, owner, "wrong first recipient");
        assertEq(bps1, 0.9e18, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.feeRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 0.1e18, "wrong second recipient bps");

        // Check owner governor + owner timelock
        vm.startPrank(user1);
        MEME.approve(address(stToken), type(uint256).max);
        stToken.deposit(D18_TOKEN_1, user1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);

        assertEq(governor.votingDelay(), 2 seconds, "wrong voting delay");
        assertEq(governor.votingPeriod(), 2 weeks, "wrong voting period");
        assertEq(governor.proposalThreshold(), 0.02e18, "wrong proposal threshold");
        assertEq(governor.quorumNumerator(), 0.08e18, "wrong quorum numerator");
        assertEq(governor.quorumDenominator(), 1e18, "wrong quorum denominator");
        assertEq(timelock.getMinDelay(), 2 days, "wrong timelock min delay");
        assertTrue(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)), "wrong admin role");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(governor)), "wrong admin role");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(folioDeployer)), "wrong admin role");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(governor)), "wrong admin role");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, owner), "wrong admin role");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, user2), "wrong admin role");
        assertFalse(timelock.hasRole(PROPOSER_ROLE, address(0)), "wrong proposer role");
        assertTrue(timelock.hasRole(PROPOSER_ROLE, address(governor)), "wrong proposer role");
        assertTrue(timelock.hasRole(EXECUTOR_ROLE, address(governor)), "wrong executor role");
        assertFalse(timelock.hasRole(EXECUTOR_ROLE, address(0)), "wrong executor role");
        assertTrue(timelock.hasRole(CANCELLER_ROLE, user1), "wrong canceler role");
        // Check optimistic governance

        IReserveOptimisticGovernor.OptimisticGovernanceParams memory optimisticParams = governor.optimisticParams();
        assertEq(optimisticParams.vetoDelay, 1 seconds, "wrong veto delay");
        assertEq(optimisticParams.vetoPeriod, 1 days, "wrong veto period");
        assertEq(optimisticParams.vetoThreshold, 0.05e18, "wrong veto threshold");

        assertFalse(timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, address(governor)), "wrong optimistic proposer role");

        // Check rebalance manager is properly set
        assertTrue(folio.hasRole(REBALANCE_MANAGER, address(timelock)), "wrong basket manager role");

        // Check StakingVault
        assertFalse(stToken.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)), "wrong staking vault admin role");
        assertEq(stToken.asset(), address(MEME), "wrong staking vault asset");

        address[] memory rewardTokens = IStakingVaultRewards(address(stToken)).getAllRewardTokens();
        assertEq(rewardTokens.length, 0, "wrong staking vault reward token count");
    }

    function test_createGovernedFolio_withExistingStToken() public {
        address[] memory guardians = new address[](1);
        guardians[0] = user1;

        address[] memory auctionLaunchers = new address[](1);
        auctionLaunchers[0] = auctionLauncher;

        address[] memory existingBasketManagers = new address[](1);
        existingBasketManagers[0] = dao;

        IFolioDeployer.GovRoles memory govRoles = IFolioDeployer.GovRoles(
            existingBasketManagers,
            auctionLaunchers,
            new address[](0)
        );
        address existingStToken = _deployExistingStToken(guardians);

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);

        vm.startSnapshotGas("deployGovernedFolio");
        {
            address _folio;
            address _governor;
            address _timelock;

            vm.recordLogs();
            (_folio, ) = folioDeployer.deployGovernedFolio(
                existingStToken,
                _basicDetails(),
                _additionalDetails(),
                _flags(),
                _govParams(guardians, _selectorAllowlist(Folio.openAuction.selector)),
                govRoles,
                bytes32(0)
            );
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(_countGovernanceSystemDeployments(logs), 1, "wrong governance deployment count");
            (_governor, _timelock) = _assertGovernedFolioEvent(logs, existingStToken, _folio);
            selectorRegistry = IOptimisticSelectorRegistry(_governanceSelectorRegistry(logs, _governor));
            assertFalse(selectorRegistry.isAllowed(_folio, Folio.startRebalance.selector), "wrong selector registry");
            assertTrue(selectorRegistry.isAllowed(_folio, Folio.openAuction.selector), "wrong selector registry");
            vm.stopSnapshotGas("deployGovernedFolio()");
            vm.stopPrank();
            stToken = IStakingVaultTest(existingStToken);
            folio = Folio(_folio);
            governor = IGovernorTest(_governor);
            timelock = ITimelockTest(_timelock);
        }
        assertEq(address(stToken), existingStToken, "wrong existing staking vault");

        // Check owner governor + owner timelock
        vm.startPrank(user1);
        MEME.approve(address(stToken), type(uint256).max);
        stToken.deposit(D18_TOKEN_1, user1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);

        assertEq(governor.votingDelay(), 2 seconds, "wrong voting delay");
        assertEq(governor.votingPeriod(), 2 weeks, "wrong voting period");
        assertEq(governor.proposalThreshold(), 0.02e18, "wrong proposal threshold");
        assertEq(governor.quorumNumerator(), 0.08e18, "wrong quorum numerator");
        assertEq(governor.quorumDenominator(), 1e18, "wrong quorum denominator");
        assertEq(timelock.getMinDelay(), 2 days, "wrong timelock min delay");
        assertTrue(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)), "wrong admin role");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(governor)), "wrong admin role");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(folioDeployer)), "wrong admin role");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(governor)), "wrong admin role");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, owner), "wrong admin role");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, user2), "wrong admin role");
        assertFalse(timelock.hasRole(PROPOSER_ROLE, address(0)), "wrong proposer role");
        assertTrue(timelock.hasRole(PROPOSER_ROLE, address(governor)), "wrong proposer role");
        assertTrue(timelock.hasRole(EXECUTOR_ROLE, address(governor)), "wrong executor role");
        assertFalse(timelock.hasRole(EXECUTOR_ROLE, address(0)), "wrong executor role");
        assertTrue(timelock.hasRole(CANCELLER_ROLE, user1), "wrong canceler role");

        // Check optimistic governance
        IReserveOptimisticGovernor.OptimisticGovernanceParams memory optimisticParams = governor.optimisticParams();
        assertEq(optimisticParams.vetoDelay, 1 seconds, "wrong veto delay");
        assertEq(optimisticParams.vetoPeriod, 1 days, "wrong veto period");
        assertEq(optimisticParams.vetoThreshold, 0.05e18, "wrong veto threshold");
        assertFalse(timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, address(governor)), "wrong optimistic proposer role");

        // Check rebalance manager is properly set
        assertTrue(folio.hasRole(REBALANCE_MANAGER, dao), "wrong existing basket manager role");
        assertTrue(folio.hasRole(REBALANCE_MANAGER, address(timelock)), "wrong basket manager role");

        address[] memory rewardTokens = IStakingVaultRewards(address(stToken)).getAllRewardTokens();
        assertEq(rewardTokens.length, 0, "wrong staking vault reward token count");
    }

    function test_cannotCreateGovernedFolioWithZeroStToken() public {
        address[] memory guardians = new address[](1);
        guardians[0] = user1;

        address[] memory auctionLaunchers = new address[](1);
        auctionLaunchers[0] = auctionLauncher;

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);

        vm.expectRevert(IFolioDeployer.FolioDeployer__InvalidStToken.selector);
        folioDeployer.deployGovernedFolio(
            address(0),
            _basicDetails(),
            _additionalDetails(),
            _flags(),
            _govParams(guardians, _selectorAllowlist(Folio.startRebalance.selector)),
            IFolioDeployer.GovRoles(new address[](0), auctionLaunchers, new address[](0)),
            bytes32(0)
        );
    }

    function test_canMineVanityAddress() public {
        address[] memory guardians = new address[](1);
        guardians[0] = user1;

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);
        vm.stopPrank();

        Folio _folio;
        IFolioDeployer.GovRoles memory govRoles = IFolioDeployer.GovRoles(
            new address[](0),
            new address[](0),
            new address[](0)
        );
        address existingStToken = _deployExistingStToken(guardians);

        for (uint256 i = 0; i < 1000; i++) {
            uint256 snapshot = vm.snapshotState();

            vm.prank(owner);
            (address _folioAddr, ) = folioDeployer.deployGovernedFolio(
                existingStToken,
                _basicDetails(),
                _additionalDetails(),
                _flags(),
                _govParams(guardians, _selectorAllowlist(Folio.startRebalance.selector)),
                govRoles,
                bytes32(i)
            );
            _folio = Folio(_folioAddr);

            // get first byte
            // 152 = 160 - 8 (one byte)
            if (uint160(address(_folio)) >> 152 == uint256(uint160(0xff))) {
                break;
            }

            vm.revertToState(snapshot);
        }

        assertEq(uint160(address(_folio)) >> 152, uint256(uint160(0xff)), "failed to mine salt");
    }

    function _deployExistingStToken(address[] memory guardians) internal returns (address existingStToken) {
        IFolioDeployer.GovParams memory govParams = _govParams(guardians, new bytes4[](0));
        IReserveOptimisticGovernorDeployer.BaseDeploymentParams memory baseParams = IReserveOptimisticGovernorDeployer
            .BaseDeploymentParams({
                optimisticParams: govParams.optimisticParams,
                standardParams: govParams.standardParams,
                selectorData: new IOptimisticSelectorRegistry.SelectorData[](0),
                optimisticProposers: govParams.optimisticProposers,
                additionalGuardians: govParams.guardians,
                timelockDelay: govParams.timelockDelay,
                proposalThrottleCapacity: govParams.proposalThrottleCapacity
            });
        IReserveOptimisticGovernorDeployer.NewStakingVaultParams
            memory newStakingVaultParams = IReserveOptimisticGovernorDeployer.NewStakingVaultParams({
                underlying: IERC20Metadata(address(MEME)),
                rewardTokens: new address[](0),
                rewardHalfLife: 1 weeks,
                unstakingDelay: 1 weeks
            });

        (existingStToken, , , ) = optimisticGovernanceDeployer.deployWithNewStakingVault(
            baseParams,
            newStakingVaultParams,
            bytes32(uint256(999))
        );
    }

    function _selectorAllowlist(bytes4 selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    function _countGovernanceSystemDeployments(Vm.Log[] memory logs) internal view returns (uint256 count) {
        bytes32 eventTopic = keccak256("ReserveOptimisticGovernorSystemDeployed(address,address,address,address)");

        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(optimisticGovernanceDeployer) &&
                logs[i].topics.length > 0 &&
                logs[i].topics[0] == eventTopic
            ) {
                ++count;
            }
        }
    }

    function _assertGovernedFolioEvent(
        Vm.Log[] memory logs,
        address expectedStToken,
        address expectedFolio
    ) internal view returns (address eventGovernor, address eventTimelock) {
        Vm.Log memory log = logs[logs.length - 1];

        assertEq(log.emitter, address(folioDeployer), "wrong governed folio event emitter");
        assertEq(
            log.topics[0],
            keccak256("GovernedFolioDeployed(address,address,address,address,address,address)"),
            "wrong governed folio event"
        );
        assertEq(address(uint160(uint256(log.topics[1]))), expectedStToken, "wrong event staking vault");
        assertEq(address(uint160(uint256(log.topics[2]))), expectedFolio, "wrong event folio");

        (address ownerGovernor, address ownerTimelock, address tradingGovernor, address tradingTimelock) = abi.decode(
            log.data,
            (address, address, address, address)
        );
        assertEq(tradingGovernor, ownerGovernor, "wrong event trading governor");
        assertEq(tradingTimelock, ownerTimelock, "wrong event trading timelock");

        eventGovernor = ownerGovernor;
        eventTimelock = ownerTimelock;
    }

    function _governanceSelectorRegistry(
        Vm.Log[] memory logs,
        address expectedGovernor
    ) internal view returns (address) {
        bytes32 eventTopic = keccak256("ReserveOptimisticGovernorSystemDeployed(address,address,address,address)");

        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(optimisticGovernanceDeployer) &&
                logs[i].topics.length > 2 &&
                logs[i].topics[0] == eventTopic &&
                address(uint160(uint256(logs[i].topics[2]))) == expectedGovernor
            ) {
                return abi.decode(logs[i].data, (address));
            }
        }

        revert("governance selector registry not found");
    }

    // === Helpers ===

    function _basicDetails() internal view returns (IFolio.FolioBasicDetails memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        return
            IFolio.FolioBasicDetails({
                name: "Test Folio",
                symbol: "TFOLIO",
                assets: tokens,
                amounts: amounts,
                initialShares: INITIAL_SUPPLY
            });
    }

    function _additionalDetails() internal view returns (IFolio.FolioAdditionalDetails memory) {
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);
        return
            IFolio.FolioAdditionalDetails({
                maxAuctionLength: MAX_AUCTION_LENGTH,
                feeRecipients: recipients,
                immutableFeeRecipients: new IFolio.FeeRecipient[](0),
                tvlFee: MAX_TVL_FEE,
                mintFee: MAX_MINT_FEE,
                folioFeeForSelf: 0,
                mandate: "mandate"
            });
    }

    function _flags() internal pure returns (IFolio.FolioFlags memory) {
        return
            IFolio.FolioFlags({
                trustedFillerEnabled: true,
                rebalanceControl: IFolio.RebalanceControl({
                    weightControl: false,
                    priceControl: IFolio.PriceControl.NONE
                }),
                bidsEnabled: true
            });
    }

    function _govParams(
        address[] memory guardians,
        bytes4[] memory optimisticSelectors
    ) internal pure returns (IFolioDeployer.GovParams memory) {
        return
            IFolioDeployer.GovParams({
                optimisticParams: IReserveOptimisticGovernor.OptimisticGovernanceParams({
                    vetoDelay: 1 seconds,
                    vetoPeriod: 1 days,
                    vetoThreshold: 0.05e18
                }),
                standardParams: IReserveOptimisticGovernor.StandardGovernanceParams({
                    votingDelay: 2 seconds,
                    votingPeriod: 2 weeks,
                    voteExtension: 1 weeks,
                    proposalThreshold: 0.02e18,
                    quorumNumerator: 0.08e18
                }),
                optimisticSelectors: optimisticSelectors,
                optimisticProposers: new address[](0),
                guardians: guardians,
                timelockDelay: 2 days,
                proposalThrottleCapacity: 10
            });
    }
}
