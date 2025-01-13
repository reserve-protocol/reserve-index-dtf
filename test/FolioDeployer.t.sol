// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IFolio } from "contracts/interfaces/IFolio.sol";
import { MAX_AUCTION_LENGTH, MAX_TRADE_DELAY, MAX_FOLIO_FEE, MAX_MINTING_FEE } from "contracts/Folio.sol";
import { FolioDeployer, IFolioDeployer } from "contracts/folio/FolioDeployer.sol";
import { IGovernanceDeployer } from "@interfaces/IGovernanceDeployer.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import "./base/BaseTest.sol";

contract FolioDeployerTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;
    uint256 internal constant MAX_FOLIO_FEE_PER_SECOND = 21979552667; // D18{1/s} 50% annually, per second

    function test_constructor() public view {
        assertEq(address(folioDeployer.daoFeeRegistry()), address(daoFeeRegistry));
        assertNotEq(address(folioDeployer.folioImplementation()), address(0));
        assertEq(address(folioDeployer.governanceDeployer()), address(governanceDeployer));
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
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_FOLIO_FEE,
            MAX_MINTING_FEE,
            owner,
            dao,
            tradeLauncher
        );
        vm.stopSnapshotGas();
        vm.stopPrank();
        assertEq(folio.name(), "Test Folio", "wrong name");
        assertEq(folio.symbol(), "TFOLIO", "wrong symbol");
        assertEq(folio.decimals(), 18, "wrong decimals");
        assertEq(folio.auctionLength(), MAX_AUCTION_LENGTH, "wrong auction length");
        assertEq(folio.totalSupply(), 1e18 * 10000, "wrong total supply");
        assertEq(folio.balanceOf(owner), 1e18 * 10000, "wrong owner balance");
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 2, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K, "wrong folio usdc balance");
        assertEq(DAI.balanceOf(address(folio)), D18_TOKEN_10K, "wrong folio dai balance");
        assertEq(folio.folioFee(), MAX_FOLIO_FEE_PER_SECOND, "wrong folio fee");
        (address r1, uint256 bps1) = folio.feeRecipients(0);
        assertEq(r1, owner, "wrong first recipient");
        assertEq(bps1, 0.9e18, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.feeRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 0.1e18, "wrong second recipient bps");

        assertTrue(folio.hasRole(folio.DEFAULT_ADMIN_ROLE(), owner), "wrong admin role");

        assertTrue(folio.hasRole(folio.TRADE_PROPOSER(), dao), "wrong trade proposer role");

        assertTrue(folio.hasRole(folio.TRADE_LAUNCHER(), tradeLauncher), "wrong trade launcher role");

        assertTrue(folio.hasRole(folio.VIBES_OFFICER(), owner), "wrong vibes officer role");
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
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_FOLIO_FEE,
            0,
            owner,
            dao,
            tradeLauncher
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
        createFolio(
            tokens,
            amounts,
            1,
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_FOLIO_FEE,
            0,
            owner,
            dao,
            tradeLauncher
        );
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
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_FOLIO_FEE,
            0,
            owner,
            dao,
            tradeLauncher
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
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_FOLIO_FEE,
            0,
            owner,
            dao,
            tradeLauncher
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
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            100,
            0,
            owner,
            dao,
            tradeLauncher
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
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_FOLIO_FEE,
            0,
            owner,
            dao,
            tradeLauncher
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
        createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_TRADE_DELAY,
            1,
            recipients,
            MAX_FOLIO_FEE,
            0,
            owner,
            dao,
            tradeLauncher
        );

        vm.expectRevert(IFolio.Folio__InvalidAuctionLength.selector); // above max
        createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH + 1,
            recipients,
            MAX_FOLIO_FEE,
            0,
            owner,
            dao,
            tradeLauncher
        );

        vm.stopPrank();
    }

    function test_cannotCreateFolioWithInvalidTradeDelay() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = D6_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);

        vm.expectRevert(IFolio.Folio__InvalidTradeDelay.selector); // above max
        createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_TRADE_DELAY + 1,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_FOLIO_FEE,
            0,
            owner,
            dao,
            tradeLauncher
        );

        vm.stopPrank();
    }

    function test_createGovernedFolio() public {
        // Deploy Community Governor

        (StakingVault stToken, , ) = governanceDeployer.deployGovernedStakingToken(
            "Test Staked MEME Token",
            "STKMEME",
            MEME,
            IGovernanceDeployer.GovParams(1 days, 1 weeks, 0.01e18, 4, 1 days, user1)
        );

        // Deploy Governed Folio

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

        address[] memory tradeLaunchers = new address[](1);
        tradeLaunchers[0] = tradeLauncher;

        vm.startSnapshotGas("deployGovernedFolio");
        (
            address _folio,
            address _folioAdmin,
            address _ownerGovernor,
            address _ownerTimelock,
            address _tradingGovernor,
            address _tradingTimelock
        ) = folioDeployer.deployGovernedFolio(
                stToken,
                IFolio.FolioBasicDetails({
                    name: "Test Folio",
                    symbol: "TFOLIO",
                    assets: tokens,
                    amounts: amounts,
                    initialShares: INITIAL_SUPPLY
                }),
                IFolio.FolioAdditionalDetails({
                    tradeDelay: MAX_TRADE_DELAY,
                    auctionLength: MAX_AUCTION_LENGTH,
                    feeRecipients: recipients,
                    folioFee: MAX_FOLIO_FEE,
                    mintingFee: MAX_MINTING_FEE
                }),
                IGovernanceDeployer.GovParams(2 seconds, 2 weeks, 0.02e18, 8, 2 days, user2),
                IGovernanceDeployer.GovParams(1 seconds, 1 weeks, 0.01e18, 4, 1 days, user1),
                new address[](0),
                tradeLaunchers,
                new address[](0)
            );
        vm.stopSnapshotGas("deployGovernedFolio()");
        vm.stopPrank();
        folio = Folio(_folio);
        proxyAdmin = FolioProxyAdmin(_folioAdmin);

        // Check Folio

        assertEq(folio.symbol(), "TFOLIO", "wrong symbol");
        assertEq(folio.decimals(), 18, "wrong decimals");
        assertEq(folio.auctionLength(), MAX_AUCTION_LENGTH, "wrong auction length");
        assertEq(folio.totalSupply(), 1e18 * 10000, "wrong total supply");
        assertEq(folio.balanceOf(owner), 1e18 * 10000, "wrong owner balance");
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 2, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K, "wrong folio usdc balance");
        assertEq(DAI.balanceOf(address(folio)), D18_TOKEN_10K, "wrong folio dai balance");
        assertEq(folio.folioFee(), MAX_FOLIO_FEE_PER_SECOND, "wrong folio fee");
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

        FolioGovernor ownerGovernor = FolioGovernor(payable(_ownerGovernor));
        TimelockController ownerTimelock = TimelockController(payable(ownerGovernor.timelock()));
        assertEq(ownerGovernor.votingDelay(), 2 seconds, "wrong voting delay");
        assertEq(ownerGovernor.votingPeriod(), 2 weeks, "wrong voting period");
        assertEq(ownerGovernor.proposalThreshold(), 0.02e18, "wrong proposal threshold");
        assertEq(ownerGovernor.quorumNumerator(), 8, "wrong quorum numerator");
        assertEq(ownerGovernor.quorumDenominator(), 100, "wrong quorum denominator");
        assertEq(ownerTimelock.getMinDelay(), 2 days, "wrong timelock min delay");
        assertTrue(
            ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), address(ownerTimelock)),
            "wrong admin role"
        );
        assertFalse(ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), _ownerGovernor), "wrong admin role");
        assertFalse(
            ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), address(folioDeployer)),
            "wrong admin role"
        );
        assertFalse(ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), _ownerGovernor), "wrong admin role");
        assertFalse(ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), owner), "wrong admin role");
        assertFalse(ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), user2), "wrong admin role");
        assertFalse(ownerTimelock.hasRole(ownerTimelock.PROPOSER_ROLE(), address(0)), "wrong proposer role");
        assertTrue(ownerTimelock.hasRole(ownerTimelock.PROPOSER_ROLE(), _ownerGovernor), "wrong proposer role");
        assertTrue(ownerTimelock.hasRole(ownerTimelock.EXECUTOR_ROLE(), _ownerGovernor), "wrong executor role");
        assertFalse(ownerTimelock.hasRole(ownerTimelock.EXECUTOR_ROLE(), address(0)), "wrong executor role");
        assertTrue(ownerTimelock.hasRole(ownerTimelock.CANCELLER_ROLE(), user2), "wrong canceler role");

        // Check trading governor + trading timelock

        FolioGovernor tradingGovernor = FolioGovernor(payable(_tradingGovernor));
        TimelockController tradingTimelock = TimelockController(payable(tradingGovernor.timelock()));
        assertEq(tradingGovernor.votingDelay(), 1 seconds, "wrong voting delay");
        assertEq(tradingGovernor.votingPeriod(), 1 weeks, "wrong voting period");
        assertEq(tradingGovernor.proposalThreshold(), 0.01e18, "wrong proposal threshold");
        assertEq(tradingGovernor.quorumNumerator(), 4, "wrong quorum numerator");
        assertEq(tradingGovernor.quorumDenominator(), 100, "wrong quorum denominator");
        assertEq(tradingTimelock.getMinDelay(), 1 days, "wrong timelock min delay");
        assertTrue(
            tradingTimelock.hasRole(tradingTimelock.DEFAULT_ADMIN_ROLE(), address(tradingTimelock)),
            "wrong admin role"
        );
        assertFalse(
            tradingTimelock.hasRole(tradingTimelock.DEFAULT_ADMIN_ROLE(), _tradingGovernor),
            "wrong admin role"
        );
        assertFalse(
            tradingTimelock.hasRole(tradingTimelock.DEFAULT_ADMIN_ROLE(), address(folioDeployer)),
            "wrong admin role"
        );
        assertFalse(tradingTimelock.hasRole(tradingTimelock.DEFAULT_ADMIN_ROLE(), owner), "wrong admin role");
        assertFalse(tradingTimelock.hasRole(tradingTimelock.DEFAULT_ADMIN_ROLE(), user1), "wrong admin role");
        assertFalse(tradingTimelock.hasRole(tradingTimelock.PROPOSER_ROLE(), address(0)), "wrong proposer role");
        assertTrue(tradingTimelock.hasRole(tradingTimelock.PROPOSER_ROLE(), _tradingGovernor), "wrong proposer role");
        assertTrue(tradingTimelock.hasRole(tradingTimelock.EXECUTOR_ROLE(), _tradingGovernor), "wrong executor role");
        assertFalse(tradingTimelock.hasRole(tradingTimelock.EXECUTOR_ROLE(), address(0)), "wrong executor role");
        assertTrue(tradingTimelock.hasRole(tradingTimelock.CANCELLER_ROLE(), user1), "wrong canceler role");

        // Check trading proposer is properly set
        assertTrue(folio.hasRole(folio.TRADE_PROPOSER(), address(tradingTimelock)), "wrong trade proposer role");
    }

    function test_createGovernedFolio_withExistingTradeProposer() public {
        // Deploy Community Governor

        (StakingVault stToken, , ) = governanceDeployer.deployGovernedStakingToken(
            "Test Staked MEME Token",
            "STKMEME",
            MEME,
            IGovernanceDeployer.GovParams(1 days, 1 weeks, 0.01e18, 4, 1 days, user1)
        );

        // Deploy Governed Folio

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

        address[] memory tradeProposers = new address[](1);
        tradeProposers[0] = dao;

        address[] memory tradeLaunchers = new address[](1);
        tradeLaunchers[0] = tradeLauncher;

        vm.startSnapshotGas("deployGovernedFolio");
        (address _folio, address _folioAdmin, address _ownerGovernor, , , ) = folioDeployer.deployGovernedFolio(
            stToken,
            IFolio.FolioBasicDetails({
                name: "Test Folio",
                symbol: "TFOLIO",
                assets: tokens,
                amounts: amounts,
                initialShares: INITIAL_SUPPLY
            }),
            IFolio.FolioAdditionalDetails({
                tradeDelay: MAX_TRADE_DELAY,
                auctionLength: MAX_AUCTION_LENGTH,
                feeRecipients: recipients,
                folioFee: MAX_FOLIO_FEE,
                mintingFee: MAX_MINTING_FEE
            }),
            IGovernanceDeployer.GovParams(2 seconds, 2 weeks, 0.02e18, 8, 2 days, user2),
            IGovernanceDeployer.GovParams(1 seconds, 1 weeks, 0.01e18, 4, 1 days, user1),
            tradeProposers,
            tradeLaunchers,
            new address[](0)
        );
        vm.stopSnapshotGas("deployGovernedFolio()");
        vm.stopPrank();
        folio = Folio(_folio);
        proxyAdmin = FolioProxyAdmin(_folioAdmin);

        // Check owner governor + owner timelock
        vm.startPrank(user1);
        MEME.approve(address(stToken), type(uint256).max);
        stToken.deposit(D18_TOKEN_1, user1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);

        FolioGovernor ownerGovernor = FolioGovernor(payable(_ownerGovernor));
        TimelockController ownerTimelock = TimelockController(payable(ownerGovernor.timelock()));
        assertEq(ownerGovernor.votingDelay(), 2 seconds, "wrong voting delay");
        assertEq(ownerGovernor.votingPeriod(), 2 weeks, "wrong voting period");
        assertEq(ownerGovernor.proposalThreshold(), 0.02e18, "wrong proposal threshold");
        assertEq(ownerGovernor.quorumNumerator(), 8, "wrong quorum numerator");
        assertEq(ownerGovernor.quorumDenominator(), 100, "wrong quorum denominator");
        assertEq(ownerTimelock.getMinDelay(), 2 days, "wrong timelock min delay");
        assertTrue(
            ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), address(ownerTimelock)),
            "wrong admin role"
        );
        assertFalse(ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), _ownerGovernor), "wrong admin role");
        assertFalse(
            ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), address(folioDeployer)),
            "wrong admin role"
        );
        assertFalse(ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), _ownerGovernor), "wrong admin role");
        assertFalse(ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), owner), "wrong admin role");
        assertFalse(ownerTimelock.hasRole(ownerTimelock.DEFAULT_ADMIN_ROLE(), user2), "wrong admin role");
        assertFalse(ownerTimelock.hasRole(ownerTimelock.PROPOSER_ROLE(), address(0)), "wrong proposer role");
        assertTrue(ownerTimelock.hasRole(ownerTimelock.PROPOSER_ROLE(), _ownerGovernor), "wrong proposer role");
        assertTrue(ownerTimelock.hasRole(ownerTimelock.EXECUTOR_ROLE(), _ownerGovernor), "wrong executor role");
        assertFalse(ownerTimelock.hasRole(ownerTimelock.EXECUTOR_ROLE(), address(0)), "wrong executor role");
        assertTrue(ownerTimelock.hasRole(ownerTimelock.CANCELLER_ROLE(), user2), "wrong canceler role");

        // Check trading proposer is properly set
        assertTrue(folio.hasRole(folio.TRADE_PROPOSER(), dao), "wrong trade proposer role");
    }
}
