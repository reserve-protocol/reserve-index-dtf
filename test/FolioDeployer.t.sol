// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { OPTIMISTIC_PROPOSER_ROLE } from "@reserve-protocol/reserve-governor/contracts/utils/Constants.sol";
import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";
import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { MAX_AUCTION_LENGTH, MAX_TVL_FEE, MAX_MINT_FEE } from "@utils/Constants.sol";
import { FolioDeployer, IFolioDeployer } from "@deployer/FolioDeployer.sol";
import { PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE, AUCTION_LAUNCHER, BRAND_MANAGER, REBALANCE_MANAGER, DEFAULT_ADMIN_ROLE } from "@utils/Constants.sol";
import "./base/BaseTest.sol";

/// @dev Extended interfaces for testing - includes methods not in the base interfaces
interface IStakingVaultTest is IERC5805, IERC4626 {
    function owner() external view returns (address);
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

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);

        address[] memory auctionLaunchers = new address[](1);
        auctionLaunchers[0] = auctionLauncher;

        {
            // stack-too-deep
            address _stToken;
            address _folio;
            address _proxyAdmin;
            address _governor;
            address _timelock;
            address _selectorRegistry;

            vm.startSnapshotGas("deployGovernedFolio");
            vm.recordLogs();
            (_stToken, _folio, _proxyAdmin, _governor, _timelock, _selectorRegistry) = folioDeployer
                .deployGovernedFolio(
                    _basicDetails(),
                    _additionalDetails(),
                    _flags(),
                    _govParams(guardians, address(MEME)),
                    IFolioDeployer.GovRoles(new address[](0), auctionLaunchers, new address[](0)),
                    bytes32(0)
                );
            vm.stopSnapshotGas("deployGovernedFolio()");
            vm.stopPrank();
            stToken = IStakingVaultTest(_stToken);
            governor = IGovernorTest(_governor);
            timelock = ITimelockTest(_timelock);
            selectorRegistry = IOptimisticSelectorRegistry(_selectorRegistry);
            folio = Folio(_folio);
            proxyAdmin = FolioProxyAdmin(_proxyAdmin);
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
        assertEq(stToken.owner(), address(timelock), "wrong staking vault owner");
        assertEq(stToken.asset(), address(MEME), "wrong staking vault asset");
    }

    function test_createGovernedFolio_withExistingRebalanceManager() public {
        address[] memory guardians = new address[](1);
        guardians[0] = user1;

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);

        address[] memory rebalanceManagers = new address[](1);
        rebalanceManagers[0] = dao;

        address[] memory auctionLaunchers = new address[](1);
        auctionLaunchers[0] = auctionLauncher;

        vm.startSnapshotGas("deployGovernedFolio");
        {
            address _stToken;
            address _folio;
            address _proxyAdmin;
            address _governor;
            address _timelock;
            address _selectorRegistry;

            (_stToken, _folio, _proxyAdmin, _governor, _timelock, _selectorRegistry) = folioDeployer
                .deployGovernedFolio(
                    _basicDetails(),
                    _additionalDetails(),
                    _flags(),
                    _govParams(guardians, address(MEME)),
                    IFolioDeployer.GovRoles(rebalanceManagers, auctionLaunchers, new address[](0)),
                    bytes32(0)
                );
            vm.stopSnapshotGas("deployGovernedFolio()");
            vm.stopPrank();
            stToken = IStakingVaultTest(_stToken);
            folio = Folio(_folio);
            proxyAdmin = FolioProxyAdmin(_proxyAdmin);
            governor = IGovernorTest(_governor);
            timelock = ITimelockTest(_timelock);
            selectorRegistry = IOptimisticSelectorRegistry(_selectorRegistry);
        }

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
        assertTrue(folio.hasRole(REBALANCE_MANAGER, dao), "wrong basket manager role");
    }

    function test_canMineVanityAddress() public {
        address[] memory guardians = new address[](1);
        guardians[0] = user1;

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);

        Folio _folio;

        for (uint256 i = 0; i < 1000; i++) {
            uint256 snapshot = vm.snapshotState();

            (, address _folioAddr, , , , ) = folioDeployer.deployGovernedFolio(
                _basicDetails(),
                _additionalDetails(),
                _flags(),
                _govParams(guardians, address(MEME)),
                IFolioDeployer.GovRoles(new address[](0), new address[](0), new address[](0)),
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
        address underlying
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
                optimisticSelectorData: new IOptimisticSelectorRegistry.SelectorData[](0),
                optimisticProposers: new address[](0),
                guardians: guardians,
                timelockDelay: 2 days,
                proposalThrottleCapacity: 10,
                underlying: underlying
            });
    }
}
