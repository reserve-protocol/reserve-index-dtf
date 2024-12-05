// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio, MAX_AUCTION_LENGTH, MAX_FEE } from "contracts/Folio.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
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
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9000);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1000);

        // 50% folio fee annually
        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        DAI.approve(address(folioFactory), type(uint256).max);
        MEME.approve(address(folioFactory), type(uint256).max);
        folio = Folio(
            folioFactory.createFolio(
                "Test Folio",
                "TFOLIO",
                MAX_AUCTION_LENGTH,
                tokens,
                amounts,
                INITIAL_SUPPLY,
                recipients,
                MAX_FEE, // 50% annually
                owner
            )
        );
        folio.grantRole(folio.TRADE_PROPOSER(), owner);
        folio.grantRole(folio.PRICE_CURATOR(), owner);
        folio.grantRole(folio.TRADE_PROPOSER(), dao);
        folio.grantRole(folio.PRICE_CURATOR(), dao);
        folio.grantRole(folio.PRICE_CURATOR(), priceCurator);
        vm.stopPrank();
    }

    function test_deployment() public {
        _deployTestFolio();
        assertEq(folio.name(), "Test Folio", "wrong name");
        assertEq(folio.symbol(), "TFOLIO", "wrong symbol");
        assertEq(folio.decimals(), 18, "wrong decimals");
        assertEq(folio.totalSupply(), INITIAL_SUPPLY, "wrong total supply");
        assertEq(folio.balanceOf(owner), INITIAL_SUPPLY, "wrong owner balance");
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 3, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(_assets[2], address(MEME), "wrong third asset");
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K, "wrong folio usdc balance");
        assertEq(DAI.balanceOf(address(folio)), D18_TOKEN_10K, "wrong folio dai balance");
        assertEq(MEME.balanceOf(address(folio)), D27_TOKEN_10K, "wrong folio meme balance");
        assertEq(folio.folioFee(), MAX_FEE, "wrong folio fee");
        (address r1, uint256 bps1) = folio.feeRecipients(0);
        assertEq(r1, owner, "wrong first recipient");
        assertEq(bps1, 9000, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.feeRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 1000, "wrong second recipient bps");
        assertEq(folio.version(), "1.0.0");
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
    //     uint256 demFee = folio.folioFee();
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
        folio.redeem(5e21, user1);
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
        uint256 supplyBefore = folio.totalSupply();

        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        // validate pending fees have been accumulated -- 50% fee = 100% of supply
        assertApproxEqAbs(supplyBefore, pendingFeeShares, 1e12, "wrong pending fee shares");

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

    function test_setFeeRecipients() public {
        _deployTestFolio();
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](3);
        recipients[0] = IFolio.FeeRecipient(owner, 8000);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 500);
        recipients[2] = IFolio.FeeRecipient(user1, 1500);
        folio.setFeeRecipients(recipients);

        (address r1, uint256 bps1) = folio.feeRecipients(0);
        assertEq(r1, owner, "wrong first recipient");
        assertEq(bps1, 8000, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.feeRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 500, "wrong second recipient bps");
        (address r3, uint256 bps3) = folio.feeRecipients(2);
        assertEq(r3, user1, "wrong third recipient");
        assertEq(bps3, 1500, "wrong third recipient bps");
    }

    function test_cannotsetFeeRecipientsIfNotOwner() public {
        _deployTestFolio();
        vm.startPrank(user1);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](3);
        recipients[0] = IFolio.FeeRecipient(owner, 8000);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 500);
        recipients[2] = IFolio.FeeRecipient(user1, 1500);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.setFeeRecipients(recipients);
    }

    function test_setFeeRecipients_DistributesFees() public {
        _deployTestFolio();

        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        uint256 initialOwnerShares = folio.balanceOf(owner);
        uint256 initialDaoShares = folio.balanceOf(dao);

        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](3);
        recipients[0] = IFolio.FeeRecipient(owner, 8000);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 500);
        recipients[2] = IFolio.FeeRecipient(user1, 1500);
        folio.setFeeRecipients(recipients);

        assertEq(folio.pendingFeeShares(), 0, "wrong pending fee shares, after");

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares");

        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(folio.balanceOf(owner), initialOwnerShares + (remainingShares * 9000) / 10000, "wrong owner shares");
        assertEq(folio.balanceOf(feeReceiver), (remainingShares * 1000) / 10000, "wrong fee receiver shares");
    }

    function test_setFolioFee() public {
        _deployTestFolio();
        vm.startPrank(owner);
        uint256 newFolioFee = 200;
        folio.setFolioFee(newFolioFee);
        assertEq(folio.folioFee(), newFolioFee, "wrong folio fee");
    }

    function test_cannotsetFolioFeeIfNotOwner() public {
        _deployTestFolio();
        vm.startPrank(user1);
        uint256 newFolioFee = 200;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.setFolioFee(newFolioFee);
    }

    function test_setFolioFee_DistributesFees() public {
        _deployTestFolio();

        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        uint256 initialOwnerShares = folio.balanceOf(owner);
        uint256 initialDaoShares = folio.balanceOf(dao);

        vm.startPrank(owner);
        uint256 newFolioFee = 200;
        folio.setFolioFee(newFolioFee);

        assertEq(folio.pendingFeeShares(), 0, "wrong pending fee shares, after");

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares");

        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(folio.balanceOf(owner), initialOwnerShares + (remainingShares * 9000) / 10000, "wrong owner shares");
        assertEq(folio.balanceOf(feeReceiver), (remainingShares * 1000) / 10000, "wrong fee receiver shares");
    }

    function test_setFolioFee_InvalidFee() public {
        _deployTestFolio();
        vm.startPrank(owner);
        uint256 newFolioFee = MAX_FEE + 1;
        vm.expectRevert(IFolio.Folio__FeeTooHigh.selector);
        folio.setFolioFee(newFolioFee);
    }

    function test_setFolioFeeRecipients_InvalidRecipient() public {
        _deployTestFolio();
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](1);
        recipients[0] = IFolio.FeeRecipient(address(0), 1000);
        vm.expectRevert(IFolio.Folio__FeeRecipientInvalidAddress.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFolioFeeRecipients_InvalidBps() public {
        _deployTestFolio();
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](1);
        recipients[0] = IFolio.FeeRecipient(owner, 0);
        vm.expectRevert(IFolio.Folio__FeeRecipientInvalidFeeShare.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFolioFeeRecipients_InvalidTotal() public {
        _deployTestFolio();
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9000);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 999);
        vm.expectRevert(IFolio.Folio__BadFeeTotal.selector);
        folio.setFeeRecipients(recipients);
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

        daoFeeRegistry.setTokenFeeNumerator(address(folio), 1000);

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
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 500);

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

    function test_atomicBidWithoutCallback() public {
        _deployTestFolio();

        // bid in two chunks, each for half of the volume

        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, type(uint256).max);

        vm.prank(priceCurator);
        folio.openTrade(0, 1e18, 1e18);
        folio.getPrice(0, block.timestamp); // should not revert

        vm.startPrank(user1);
        USDT.approve(address(folio), amt);
        folio.bid(0, amt / 2, amt / 2, false, bytes(""));

        // bid a 2nd time for the rest of the volume
        USDT.approve(address(folio), amt);
        folio.bid(0, amt / 2, amt / 2, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K - D6_TOKEN_1, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionBidWithoutCallback() public {
        _deployTestFolio();

        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, type(uint256).max);

        vm.prank(priceCurator);
        folio.openTrade(0, 10e18, 1e18); // 10x -> 1x

        (, , , , , , , uint256 start, uint256 end) = folio.trades(0);
        assertEq(folio.getBidAmount(0, amt, start), amt * 10, "wrong start bid amount"); // 10x
        assertEq(folio.getBidAmount(0, amt, (start + end) / 2), 3162278, "wrong mid bid amount"); // ~3.16x
        assertEq(folio.getBidAmount(0, amt, end), amt + 1, "wrong end bid amount"); // 1x + 1
    }
}
