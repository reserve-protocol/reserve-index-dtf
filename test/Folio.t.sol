// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio } from "contracts/Folio.sol";
import "./base/BaseTest.sol";

contract FolioTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;
    function _deployTestFolio() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        tokens[2] = address(MEME);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        amounts[2] = D27_TOKEN_10K;
        IFolio.DemurrageRecipient[] memory recipients = new IFolio.DemurrageRecipient[](2);
        recipients[0] = IFolio.DemurrageRecipient(owner, 9000);
        recipients[1] = IFolio.DemurrageRecipient(feeReceiver, 1000);
        // 1% demurrage fee
        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        DAI.approve(address(folioFactory), type(uint256).max);
        MEME.approve(address(folioFactory), type(uint256).max);
        folio = Folio(
            folioFactory.createFolio("Test Folio", "TFOLIO", tokens, amounts, INITIAL_SUPPLY, 100, recipients)
        );
        vm.stopPrank();
    }

    function test_deployment() public {
        _deployTestFolio();
        assertEq(folio.name(), "Test Folio", "wrong name");
        assertEq(folio.symbol(), "TFOLIO", "wrong symbol");
        assertEq(folio.decimals(), 18, "wrong decimals");
        assertEq(folio.totalSupply(), 1e18 * 10000, "wrong total supply");
        assertEq(folio.balanceOf(owner), 1e18 * 10000, "wrong owner balance");
        assertEq(folio.assets().length, 3, "wrong assets length");
        assertEq(folio.assets()[0], address(USDC), "wrong first asset");
        assertEq(folio.assets()[1], address(DAI), "wrong second asset");
        assertEq(folio.assets()[2], address(MEME), "wrong third asset");
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K, "wrong folio usdc balance");
        assertEq(DAI.balanceOf(address(folio)), D18_TOKEN_10K, "wrong folio dai balance");
        assertEq(MEME.balanceOf(address(folio)), D27_TOKEN_10K, "wrong folio meme balance");
        assertEq(folio.demurrageFee(), 100, "wrong demurrage fee");
        (address r1, uint256 bps1) = folio.demurrageRecipients(0);
        assertEq(r1, owner, "wrong first recipient");
        assertEq(bps1, 9000, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.demurrageRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 1000, "wrong second recipient bps");
    }

    /*
        this would test if the total supply is correct, based on a call to totalSupply() that takes into account unaccounted fees
    */
    // function test_totalSupply() public {
    //     _deployTestFolio();
    //     // fast forward, accumulate fees
    //     vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
    //     vm.roll(block.number + 1000000);

    //     uint256 timeDelta = block.timestamp - folio.lastPoke();
    //     uint256 demFee = folio.demurrageFee();
    //     assertEq(
    //         folio.totalSupply(),
    //         INITIAL_SUPPLY + (((INITIAL_SUPPLY * timeDelta) / YEAR_IN_SECONDS) * demFee) / folio.BPS_PRECISION(),
    //         "wrong total supply"
    //     );
    // }

    function test_mint() public {
        _deployTestFolio();
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        uint256 startingUSDCBalance = USDC.balanceOf(address(folio));
        uint256 startingDAIBalance = DAI.balanceOf(address(folio));
        uint256 startingMEMEBalance = MEME.balanceOf(address(folio));
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);
        folio.mint(1e22, user1);
        assertEq(folio.balanceOf(user1), 1e22, "wrong user1 balance");
        assertApproxEqAbs(
            USDC.balanceOf(address(folio)),
            startingUSDCBalance + D6_TOKEN_10K,
            1,
            "wrong folio usdc balance"
        );
        assertApproxEqAbs(
            DAI.balanceOf(address(folio)),
            startingDAIBalance + D18_TOKEN_10K,
            1,
            "wrong folio dai balance"
        );
        assertApproxEqAbs(
            MEME.balanceOf(address(folio)),
            startingMEMEBalance + D27_TOKEN_10K,
            1e9,
            "wrong folio meme balance"
        );
    }

    function test_redeem() public {
        _deployTestFolio();
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);
        folio.mint(1e22, user1);
        assertEq(folio.balanceOf(user1), 1e22);
        uint256 startingUSDCBalanceFolio = USDC.balanceOf(address(folio));
        uint256 startingDAIBalanceFolio = DAI.balanceOf(address(folio));
        uint256 startingMEMEBalanceFolio = MEME.balanceOf(address(folio));
        uint256 startingUSDCBalanceAlice = USDC.balanceOf(address(user1));
        uint256 startingDAIBalanceAlice = DAI.balanceOf(address(user1));
        uint256 startingMEMEBalanceAlice = MEME.balanceOf(address(user1));
        folio.redeem(5e21, user1, user1);
        assertApproxEqAbs(
            USDC.balanceOf(address(folio)),
            startingUSDCBalanceFolio - D6_TOKEN_10K / 2,
            1,
            "wrong folio usdc balance"
        );
        assertApproxEqAbs(
            DAI.balanceOf(address(folio)),
            startingDAIBalanceFolio - D18_TOKEN_10K / 2,
            1,
            "wrong folio dai balance"
        );
        assertApproxEqAbs(
            MEME.balanceOf(address(folio)),
            startingMEMEBalanceFolio - D27_TOKEN_10K / 2,
            1e9,
            "wrong folio meme balance"
        );
        assertApproxEqAbs(
            USDC.balanceOf(user1),
            startingUSDCBalanceAlice + D6_TOKEN_10K / 2,
            1,
            "wrong alice usdc balance"
        );
        assertApproxEqAbs(
            DAI.balanceOf(user1),
            startingDAIBalanceAlice + D18_TOKEN_10K / 2,
            1,
            "wrong alice dai balance"
        );
        assertApproxEqAbs(
            MEME.balanceOf(user1),
            startingMEMEBalanceAlice + D27_TOKEN_10K / 2,
            1e9,
            "wrong alice meme balance"
        );
    }

    function test_daoFee() public {
        _deployTestFolio();

        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        // validate pending fees have been accumulated
        uint256 currentSupply = folio.totalSupply();
        uint256 demFeeBps = folio.demurrageFee();
        uint256 expectedFeeShares = (currentSupply * demFeeBps) / 1e4 / 2;
        assertEq(expectedFeeShares, pendingFeeShares, "wrong pending fee shares");

        uint256 initialOwnerShares = folio.balanceOf(owner);
        folio.distributeFees();

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares");

        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(folio.balanceOf(owner), initialOwnerShares + (remainingShares * 9000) / 10000, "wrong owner shares");
        assertEq(folio.balanceOf(feeReceiver), (remainingShares * 1000) / 10000, "wrong fee receiver shares");
    }

    function test_setDemurrageRecipients() public {
        _deployTestFolio();
        vm.startPrank(owner);
        IFolio.DemurrageRecipient[] memory recipients = new IFolio.DemurrageRecipient[](3);
        recipients[0] = IFolio.DemurrageRecipient(owner, 8000);
        recipients[1] = IFolio.DemurrageRecipient(feeReceiver, 500);
        recipients[2] = IFolio.DemurrageRecipient(user1, 1500);
        folio.setDemurrageRecipients(recipients);

        (address r1, uint256 bps1) = folio.demurrageRecipients(0);
        assertEq(r1, owner, "wrong first recipient");
        assertEq(bps1, 8000, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.demurrageRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 500, "wrong second recipient bps");
        (address r3, uint256 bps3) = folio.demurrageRecipients(2);
        assertEq(r3, user1, "wrong third recipient");
        assertEq(bps3, 1500, "wrong third recipient bps");
    }

    function test_setDemurrageRecipients_DistributesFees() public {
        _deployTestFolio();

        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        uint256 initialOwnerShares = folio.balanceOf(owner);
        uint256 initialDaoShares = folio.balanceOf(dao);

        vm.startPrank(owner);
        IFolio.DemurrageRecipient[] memory recipients = new IFolio.DemurrageRecipient[](3);
        recipients[0] = IFolio.DemurrageRecipient(owner, 8000);
        recipients[1] = IFolio.DemurrageRecipient(feeReceiver, 500);
        recipients[2] = IFolio.DemurrageRecipient(user1, 1500);
        folio.setDemurrageRecipients(recipients);

        assertEq(folio.pendingFeeShares(), 0, "wrong pending fee shares, after");

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares");

        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(folio.balanceOf(owner), initialOwnerShares + (remainingShares * 9000) / 10000, "wrong owner shares");
        assertEq(folio.balanceOf(feeReceiver), (remainingShares * 1000) / 10000, "wrong fee receiver shares");
    }

    function test_setDemurrageFee() public {
        _deployTestFolio();
        vm.startPrank(owner);
        uint256 newDemurrageFee = 200;
        folio.setDemurrageFee(newDemurrageFee);
        assertEq(folio.demurrageFee(), newDemurrageFee, "wrong demurrage fee");
    }

    function test_setDemurrageFee_DistributesFees() public {
        _deployTestFolio();

        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        uint256 initialOwnerShares = folio.balanceOf(owner);
        uint256 initialDaoShares = folio.balanceOf(dao);

        vm.startPrank(owner);
        uint256 newDemurrageFee = 200;
        folio.setDemurrageFee(newDemurrageFee);

        assertEq(folio.pendingFeeShares(), 0, "wrong pending fee shares, after");

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares");

        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(folio.balanceOf(owner), initialOwnerShares + (remainingShares * 9000) / 10000, "wrong owner shares");
        assertEq(folio.balanceOf(feeReceiver), (remainingShares * 1000) / 10000, "wrong fee receiver shares");
    }

    function test_setDemurrageFee_InvalidFee() public {
        _deployTestFolio();
        vm.startPrank(owner);
        uint256 newDemurrageFee = 50001; // above max
        vm.expectRevert(IFolio.Folio_badDemurrageFee.selector);
        folio.setDemurrageFee(newDemurrageFee);
    }

    function test_setDemurrageFeeRecipients_InvalidRecipient() public {
        _deployTestFolio();
        vm.startPrank(owner);
        IFolio.DemurrageRecipient[] memory recipients = new IFolio.DemurrageRecipient[](1);
        recipients[0] = IFolio.DemurrageRecipient(address(0), 1000);
        vm.expectRevert(IFolio.Folio_badDemurrageFeeRecipientAddress.selector);
        folio.setDemurrageRecipients(recipients);
    }

    function test_setDemurrageFeeRecipients_InvalidBps() public {
        _deployTestFolio();
        vm.startPrank(owner);
        IFolio.DemurrageRecipient[] memory recipients = new IFolio.DemurrageRecipient[](1);
        recipients[0] = IFolio.DemurrageRecipient(owner, 0);
        vm.expectRevert(IFolio.Folio_badDemurrageFeeRecipientBps.selector);
        folio.setDemurrageRecipients(recipients);
    }

    function test_setDemurrageFeeRecipients_InvalidTotal() public {
        _deployTestFolio();
        vm.startPrank(owner);
        IFolio.DemurrageRecipient[] memory recipients = new IFolio.DemurrageRecipient[](2);
        recipients[0] = IFolio.DemurrageRecipient(owner, 9000);
        recipients[1] = IFolio.DemurrageRecipient(feeReceiver, 999);
        vm.expectRevert(IFolio.Folio_badDemurrageFeeTotal.selector);
        folio.setDemurrageRecipients(recipients);
    }

    function test_setFolioFeeRegistry() public {
        _deployTestFolio();

        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        uint256 initialOwnerShares = folio.balanceOf(owner);
        uint256 initialDaoShares = folio.balanceOf(dao);
        uint256 initialFeeReceiverShares = folio.balanceOf(feeReceiver);

        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));

        daoFeeRegistry.setRTokenFeeNumerator(address(folio), 1000);

        // check receipient balances
        uint256 expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares, 1st change");
        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(
            folio.balanceOf(owner),
            initialOwnerShares + (remainingShares * 9000) / 10000,
            "wrong owner shares, 1st change"
        );
        assertEq(
            folio.balanceOf(feeReceiver),
            initialFeeReceiverShares + (remainingShares * 1000) / 10000,
            "wrong fee receiver shares, 1st change"
        );

        // fast forward again, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);

        pendingFeeShares = folio.getPendingFeeShares();

        initialOwnerShares = folio.balanceOf(owner);
        initialDaoShares = folio.balanceOf(dao);
        initialFeeReceiverShares = folio.balanceOf(feeReceiver);
        (, daoFeeNumerator, daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));

        // set new fee numerator, should distribute fees
        daoFeeRegistry.setRTokenFeeNumerator(address(folio), 500);

        // check receipient balances
        expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares, 2nd change");
        remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(
            folio.balanceOf(owner),
            initialOwnerShares + (remainingShares * 9000) / 10000,
            "wrong owner shares, 2nd change"
        );
        assertEq(
            folio.balanceOf(feeReceiver),
            initialFeeReceiverShares + (remainingShares * 1000) / 10000,
            "wrong fee receiver shares, 2nd change"
        );
    }
}
