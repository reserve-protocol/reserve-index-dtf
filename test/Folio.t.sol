// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio, MAX_AUCTION_LENGTH, MIN_AUCTION_LENGTH, MAX_FEE, MAX_TRADE_DELAY } from "contracts/Folio.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import "./base/BaseTest.sol";

contract FolioTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;

    function _testSetup() public virtual override {
        super._testSetup();
        _deployTestFolio();
    }

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
        recipients[0] = IFolio.FeeRecipient(owner, 9e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1e17);

        // 50% folio fee annually
        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        DAI.approve(address(folioFactory), type(uint256).max);
        MEME.approve(address(folioFactory), type(uint256).max);
        folio = Folio(
            folioFactory.createFolio(
                "Test Folio",
                "TFOLIO",
                MAX_TRADE_DELAY,
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
        folio.grantRole(folio.PRICE_CURATOR(), priceCurator);
        vm.stopPrank();
    }

    function test_deployment() public view {
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
        assertEq(bps1, 9e17, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.feeRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 1e17, "wrong second recipient bps");
        assertEq(folio.version(), "1.0.0");
    }

    function test_mint() public {
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
        assertEq(folio.balanceOf(owner), initialOwnerShares + (remainingShares * 9e17) / 1e18, "wrong owner shares");
        assertEq(folio.balanceOf(feeReceiver), (remainingShares * 1e17) / 1e18, "wrong fee receiver shares");
    }

    function test_setFeeRecipients() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](3);
        recipients[0] = IFolio.FeeRecipient(owner, 8e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 5e16);
        recipients[2] = IFolio.FeeRecipient(user1, 15e16);
        folio.setFeeRecipients(recipients);

        (address r1, uint256 bps1) = folio.feeRecipients(0);
        assertEq(r1, owner, "wrong first recipient");
        assertEq(bps1, 8e17, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.feeRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 5e16, "wrong second recipient bps");
        (address r3, uint256 bps3) = folio.feeRecipients(2);
        assertEq(r3, user1, "wrong third recipient");
        assertEq(bps3, 15e16, "wrong third recipient bps");
    }

    function test_cannotSetFeeRecipientsIfNotOwner() public {
        vm.startPrank(user1);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](3);
        recipients[0] = IFolio.FeeRecipient(owner, 8e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 5e16);
        recipients[2] = IFolio.FeeRecipient(user1, 15e16);
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
        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        uint256 initialOwnerShares = folio.balanceOf(owner);
        uint256 initialDaoShares = folio.balanceOf(dao);

        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](3);
        recipients[0] = IFolio.FeeRecipient(owner, 8e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 5e16);
        recipients[2] = IFolio.FeeRecipient(user1, 15e16);
        folio.setFeeRecipients(recipients);

        assertEq(folio.pendingFeeShares(), 0, "wrong pending fee shares, after");

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares");

        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(folio.balanceOf(owner), initialOwnerShares + (remainingShares * 9e17) / 1e18, "wrong owner shares");
        assertEq(folio.balanceOf(feeReceiver), (remainingShares * 1e17) / 1e18, "wrong fee receiver shares");
    }

    function test_setFolioFee() public {
        vm.startPrank(owner);
        assertEq(folio.folioFee(), MAX_FEE, "wrong folio fee");
        uint256 newFolioFee = 200;
        folio.setFolioFee(newFolioFee);
        assertEq(folio.folioFee(), newFolioFee, "wrong folio fee");
    }

    function test_setTradeDelay() public {
        vm.startPrank(owner);
        assertEq(folio.tradeDelay(), MAX_TRADE_DELAY, "wrong trade delay");
        uint256 newAuctionLength = 0;
        folio.setTradeDelay(newAuctionLength);
        assertEq(folio.tradeDelay(), newAuctionLength, "wrong trade delay");
    }

    function test_setAuctionLength() public {
        vm.startPrank(owner);
        assertEq(folio.auctionLength(), MAX_AUCTION_LENGTH, "wrong auction length");
        uint256 newAuctionLength = MIN_AUCTION_LENGTH;
        folio.setAuctionLength(newAuctionLength);
        assertEq(folio.auctionLength(), newAuctionLength, "wrong auction length");
    }

    function test_cannotSetFolioFeeIfNotOwner() public {
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
        assertEq(folio.balanceOf(owner), initialOwnerShares + (remainingShares * 9e17) / 1e18, "wrong owner shares");
        assertEq(folio.balanceOf(feeReceiver), (remainingShares * 1e17) / 1e18, "wrong fee receiver shares");
    }

    function test_setFolioFee_InvalidFee() public {
        vm.startPrank(owner);
        uint256 newFolioFee = MAX_FEE + 1;
        vm.expectRevert(IFolio.Folio__FeeTooHigh.selector);
        folio.setFolioFee(newFolioFee);
    }

    function test_setFolioFeeRecipients_InvalidRecipient() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](1);
        recipients[0] = IFolio.FeeRecipient(address(0), 1e17);
        vm.expectRevert(IFolio.Folio__FeeRecipientInvalidAddress.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFolioFeeRecipients_InvalidBps() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](1);
        recipients[0] = IFolio.FeeRecipient(owner, 0);
        vm.expectRevert(IFolio.Folio__FeeRecipientInvalidFeeShare.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFolioFeeRecipients_InvalidTotal() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 999);
        vm.expectRevert(IFolio.Folio__BadFeeTotal.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFolioDAOFeeRegistry() public {
        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        uint256 initialOwnerShares = folio.balanceOf(owner);
        uint256 initialDaoShares = folio.balanceOf(dao);
        uint256 initialFeeReceiverShares = folio.balanceOf(feeReceiver);

        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));

        daoFeeRegistry.setTokenFeeNumerator(address(folio), 1e17);

        // check receipient balances
        uint256 expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares, 1st change");
        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(
            folio.balanceOf(owner),
            initialOwnerShares + (remainingShares * 9e17) / 1e18,
            "wrong owner shares, 1st change"
        );
        assertEq(
            folio.balanceOf(feeReceiver),
            initialFeeReceiverShares + (remainingShares * 1e17) / 1e18,
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
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 5e16);

        // check receipient balances
        expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares, 2nd change");
        remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(
            folio.balanceOf(owner),
            initialOwnerShares + (remainingShares * 9e17) / 1e18,
            "wrong owner shares, 2nd change"
        );
        assertEq(
            folio.balanceOf(feeReceiver),
            initialFeeReceiverShares + (remainingShares * 1e17) / 1e18,
            "wrong fee receiver shares, 2nd change"
        );
    }

    function test_atomicBidWithoutCallback() public {
        // bid in two chunks, one at start time and one at end time

        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, type(uint256).max);

        vm.prank(priceCurator);
        folio.openTrade(0, 1e18, 1e18);

        // bid once at start time

        vm.startPrank(user1);
        USDT.approve(address(folio), amt);
        folio.bid(0, amt / 2, amt / 2, false, bytes(""));

        (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);
        assertEq(folio.getBidAmount(0, amt, start), amt, "wrong start bid amount"); // 1x
        assertEq(folio.getBidAmount(0, amt, (start + end) / 2), amt, "wrong mid bid amount"); // 1x
        assertEq(folio.getBidAmount(0, amt, end), amt, "wrong end bid amount"); // 1x

        // bid a 2nd time for the rest of the volume, at end time
        vm.warp(end);
        USDT.approve(address(folio), amt);
        folio.bid(0, amt / 2, amt / 2, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K - D6_TOKEN_1, "wrong usdc balance");
        vm.stopPrank();

        (, , , uint256 sellAmount, , , , , , , ) = folio.trades(0);
        assertEq(sellAmount, 0, "auction should be empty");
    }

    function test_atomicBidWithCallback() public {
        // bid in two chunks, one at start time and one at end time

        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, type(uint256).max);

        vm.prank(priceCurator);
        folio.openTrade(0, 1e18, 1e18);

        // bid once at start time

        MockBidder mockBidder = new MockBidder();
        vm.prank(user1);
        USDT.transfer(address(mockBidder), amt / 2);
        vm.prank(address(mockBidder));
        folio.bid(0, amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);
        assertEq(folio.getBidAmount(0, amt, start), amt, "wrong start bid amount"); // 1x
        assertEq(folio.getBidAmount(0, amt, (start + end) / 2), amt, "wrong mid bid amount"); // 1x
        assertEq(folio.getBidAmount(0, amt, end), amt, "wrong end bid amount"); // 1x

        // bid a 2nd time for the rest of the volume, at end time

        vm.warp(end);
        MockBidder mockBidder2 = new MockBidder();
        vm.prank(user1);
        USDT.transfer(address(mockBidder2), amt / 2);
        vm.prank(address(mockBidder2));
        folio.bid(0, amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder2)), 0, "wrong mock bidder2 balance");
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K - D6_TOKEN_1, "wrong usdc balance");
        vm.stopPrank();

        (, , , uint256 sellAmount, , , , , , , ) = folio.trades(0);
        assertEq(sellAmount, 0, "auction should be empty");
    }

    function test_auctionBidWithoutCallback() public {
        // bid in two chunks, one at start time and one at end time

        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, type(uint256).max);

        vm.prank(priceCurator);
        folio.openTrade(0, 10e18, 1e18); // 10x -> 1x

        // bid once at start time

        vm.startPrank(user1);
        USDT.approve(address(folio), amt * 5);
        folio.bid(0, amt / 2, amt * 5, false, bytes(""));

        (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);
        assertEq(folio.getBidAmount(0, amt, start), amt * 10, "wrong start bid amount"); // 10x
        assertEq(folio.getBidAmount(0, amt, (start + end) / 2), 3162278, "wrong mid bid amount"); // ~3.16x
        assertEq(folio.getBidAmount(0, amt, end), amt + 1, "wrong end bid amount"); // 1x + 1
        vm.warp(end);

        // bid a 2nd time for the rest of the volume, at end time
        USDT.approve(address(folio), amt);
        folio.bid(0, amt / 2, amt / 2 + 1, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K - D6_TOKEN_1, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionBidWithCallback() public {
        // bid in two chunks, one at start time and one at end time

        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, type(uint256).max);

        vm.prank(priceCurator);
        folio.openTrade(0, 10e18, 1e18); // 10x -> 1x

        // bid once at start time

        MockBidder mockBidder = new MockBidder();
        vm.prank(user1);
        USDT.transfer(address(mockBidder), amt * 5);
        vm.prank(address(mockBidder));
        folio.bid(0, amt / 2, amt * 5, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        // check prices

        (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);
        assertEq(folio.getBidAmount(0, amt, start), amt * 10, "wrong start bid amount"); // 10x
        assertEq(folio.getBidAmount(0, amt, (start + end) / 2), 3162278, "wrong mid bid amount"); // ~3.16x
        assertEq(folio.getBidAmount(0, amt, end), amt + 1, "wrong end bid amount"); // 1x + 1

        // bid a 2nd time for the rest of the volume, at end time

        vm.warp(end);
        MockBidder mockBidder2 = new MockBidder();
        vm.prank(user1);
        USDT.transfer(address(mockBidder2), amt / 2 + 1);
        vm.prank(address(mockBidder2));
        folio.bid(0, amt / 2, amt / 2 + 1, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder2)), 0, "wrong mock bidder2 balance");
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K - D6_TOKEN_1, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionKillTrade() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, type(uint256).max);

        vm.startPrank(priceCurator);
        folio.openTrade(0, 10e18, 1e18); // 10x -> 1x
        folio.killTrade(0);

        // next auction index should revert

        vm.expectRevert();
        folio.killTrade(1); // index out of bounds

        (, , , , , , , , , uint256 end, ) = folio.trades(0);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctionNotOpenableUntilApproved() public {
        // should not be openable until approved

        vm.prank(dao);
        vm.expectRevert();
        folio.openTrade(0, 10e18, 1e18); // 10x -> 1x
    }

    function test_auctionNotLaunchableAfterTimeout() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, 1 days);

        // should not be openable after launchTimeout

        (, , , , , , , uint256 launchTimeout, , , ) = folio.trades(0);
        vm.warp(launchTimeout + 1);
        vm.prank(priceCurator);
        vm.expectRevert(IFolio.Folio__TradeTimeout.selector);
        folio.openTrade(0, 10e18, 1e18); // 10x -> 1x
    }

    function test_auctionNotAvailableBeforeOpen() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, type(uint256).max);

        // auction should not be biddable before openTrade

        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
    }

    function test_auctionNotAvailableAfterEnd() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, type(uint256).max);

        vm.prank(priceCurator);
        folio.openTrade(0, 10e18, 1e18); // 10x -> 1x

        // auction should not biddable after end

        (, , , , , , , , , uint256 end, ) = folio.trades(0);
        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
    }

    function test_auctionRequiresBalanceToOpen() public {
        // can approve trade without balance

        uint256 bal = USDC.balanceOf(address(folio));
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, bal + 1, 0, 0, type(uint256).max);

        // cannot open trade without balance

        vm.prank(priceCurator);
        vm.expectRevert(IFolio.Folio__InsufficientBalance.selector);
        folio.openTrade(0, 10e18, 1e18);
    }

    function test_auctionOnlyPriceCuratorCanBypassDelay() public {
        uint256 amt = D6_TOKEN_1;
        vm.startPrank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, type(uint256).max);

        // dao should not be able to open trade

        vm.expectRevert(IFolio.Folio__TradeCannotBeOpened.selector);
        folio.openTrade(0, 10e18, 1e18); // 10x -> 1x
        vm.stopPrank();

        // price curator should be able to open trade
        vm.prank(priceCurator);
        folio.openTrade(0, 10e18, 1e18); // 10x -> 1x
    }

    function test_parallelAuctions() public {
        // launch two auction in parallel to sell ALL USDC/DAI

        uint256 amt1 = USDC.balanceOf(address(folio));
        uint256 amt2 = DAI.balanceOf(address(folio));
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt1, 0, 0, type(uint256).max);
        vm.prank(dao);
        folio.approveTrade(1, DAI, USDT, amt2, 0, 0, type(uint256).max);

        vm.prank(priceCurator);
        folio.openTrade(0, 10e18, 1e18); // 10x -> 1x
        vm.prank(priceCurator);
        folio.openTrade(1, 100e6, 1e6); // 100x -> 1x

        // bid in first auction for half volume at start

        vm.startPrank(user1);
        USDT.approve(address(folio), amt1 * 5);
        folio.bid(0, amt1 / 2, amt1 * 5, false, bytes(""));

        // advance halfway and bid for full volume of second auction

        (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);
        vm.warp(start + (end - start) / 2);
        uint256 bidAmt = (amt2 * 40) / 1e12; // adjust for decimals
        USDT.approve(address(folio), bidAmt);
        folio.bid(1, amt2, bidAmt, false, bytes("")); // ~31.6x

        // advance to end and bid for rest of first auction

        vm.warp(end);
        USDT.approve(address(folio), amt1 / 2 + 1);
        folio.bid(0, amt1 / 2, amt1 / 2 + 1, false, bytes(""));

        // auctions are over, should have no USDC + DAI left

        (, , , uint256 sellAmount, , , , , , , ) = folio.trades(0);
        assertEq(sellAmount, 0, "unfinished auction 1");
        (, , , sellAmount, , , , , , , ) = folio.trades(1);
        assertEq(sellAmount, 0, "unfinished auction 2");
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        assertEq(DAI.balanceOf(address(folio)), 0, "wrong dai balance");
    }

    function test_priceCalculationGasCost() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(0, USDC, USDT, amt, 0, 0, type(uint256).max);

        vm.prank(priceCurator);
        folio.openTrade(0, 10e18, 1e18); // 10x -> 1x
        (, , , , , , , , , uint256 end, ) = folio.trades(0);

        vm.startSnapshotGas("getPrice()");
        folio.getPrice(0, end);
        vm.stopSnapshotGas();
    }
}
