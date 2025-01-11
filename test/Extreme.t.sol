// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio, MAX_AUCTION_LENGTH, MAX_TRADE_DELAY, MAX_FOLIO_FEE_ANNUALLY, MAX_TTL, MAX_PRICE_RANGE, MAX_EXCHANGE_RATE } from "contracts/Folio.sol";
import "./base/BaseExtremeTest.sol";

contract ExtremeTest is BaseExtremeTest {
    function _deployTestFolio(
        address[] memory _tokens,
        uint256[] memory _amounts,
        uint256 initialSupply,
        uint256 folioFee,
        uint256 mintingFee,
        IFolio.FeeRecipient[] memory recipients
    ) public {
        string memory deployGasTag = string.concat(
            "deployFolio(",
            vm.toString(_tokens.length),
            " tokens, ",
            vm.toString(initialSupply),
            " amount, ",
            vm.toString(IERC20Metadata(_tokens[0]).decimals()),
            " decimals)"
        );

        // create folio
        vm.startPrank(owner);
        for (uint256 i = 0; i < _tokens.length; i++) {
            IERC20(_tokens[i]).approve(address(folioDeployer), type(uint256).max);
        }
        vm.startSnapshotGas(deployGasTag);
        (folio, proxyAdmin) = createFolio(
            _tokens,
            _amounts,
            initialSupply,
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            folioFee,
            mintingFee,
            owner,
            dao,
            priceCurator
        );
        vm.stopSnapshotGas(deployGasTag);
        vm.stopPrank();
    }

    function test_mint_redeem_extreme() public {
        // Process all test combinations
        for (uint256 i; i < mintRedeemTestParams.length; i++) {
            run_mint_redeem_scenario(mintRedeemTestParams[i]);
        }
    }

    function test_trading_extreme() public {
        // Process all test combinations
        for (uint256 i; i < tradingTestParams.length; i++) {
            run_trading_scenario(tradingTestParams[i]);
        }
    }

    function test_fees_extreme() public {
        deployCoins();

        // Process all test combinations
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < feeTestParams.length; i++) {
            run_fees_scenario(feeTestParams[i]);
            vm.revertToState(snapshot);
        }
    }

    function run_mint_redeem_scenario(MintRedeemTestParams memory p) public {
        string memory mintGasTag = string.concat(
            "mint(",
            vm.toString(p.numTokens),
            " tokens, ",
            vm.toString(p.amount),
            " amount, ",
            vm.toString(p.decimals),
            " decimals)"
        );
        string memory redeemGasTag = string.concat(
            "redeem(",
            vm.toString(p.numTokens),
            " tokens, ",
            vm.toString(p.amount),
            " amount, ",
            vm.toString(p.decimals),
            " decimals)"
        );

        // Create and mint tokens
        address[] memory tokens = new address[](p.numTokens);
        uint256[] memory amounts = new uint256[](p.numTokens);
        for (uint256 j = 0; j < p.numTokens; j++) {
            tokens[j] = address(
                deployCoin(string(abi.encodePacked("Token", j)), string(abi.encodePacked("TKN", j)), p.decimals)
            );
            amounts[j] = p.amount;
            mintTokens(tokens[j], getActors(), amounts[j] * 2);
        }

        // deploy folio
        uint256 initialSupply = p.amount * 1e18;
        uint256 folioFee = MAX_FOLIO_FEE_ANNUALLY;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);
        _deployTestFolio(tokens, amounts, initialSupply, folioFee, 0, recipients);

        // check deployment
        assertEq(folio.totalSupply(), initialSupply, "wrong total supply");
        assertEq(folio.balanceOf(owner), initialSupply, "wrong owner balance");
        (address[] memory _assets, ) = folio.totalAssets();

        assertEq(_assets.length, p.numTokens, "wrong assets length");
        for (uint256 j = 0; j < p.numTokens; j++) {
            assertEq(_assets[j], tokens[j], "wrong asset");
            assertEq(IERC20(tokens[j]).balanceOf(address(folio)), amounts[j], "wrong folio token balance");
        }
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");

        // Mint
        vm.startPrank(user1);
        uint256[] memory startingBalancesUser = new uint256[](tokens.length);
        uint256[] memory startingBalancesFolio = new uint256[](tokens.length);
        for (uint256 j = 0; j < tokens.length; j++) {
            IERC20 _token = IERC20(tokens[j]);
            startingBalancesUser[j] = _token.balanceOf(address(user1));
            startingBalancesFolio[j] = _token.balanceOf(address(folio));
            _token.approve(address(folio), type(uint256).max);
        }
        // mint folio
        uint256 mintAmount = p.amount * 1e18;
        vm.startSnapshotGas(mintGasTag);
        folio.mint(mintAmount, user1);
        vm.stopSnapshotGas(mintGasTag);
        vm.stopPrank();

        // check balances
        assertEq(folio.balanceOf(user1), mintAmount - mintAmount / 2000, "wrong user1 balance");
        for (uint256 j = 0; j < tokens.length; j++) {
            IERC20 _token = IERC20(tokens[j]);

            uint256 tolerance = (p.decimals > 18) ? 10 ** (p.decimals - 18) : 1;
            assertApproxEqAbs(
                _token.balanceOf(address(folio)),
                startingBalancesFolio[j] + amounts[j],
                tolerance,
                "wrong folio token balance"
            );

            assertApproxEqAbs(
                _token.balanceOf(address(user1)),
                startingBalancesUser[j] - amounts[j],
                tolerance,
                "wrong user1 token balance"
            );

            // update values for redeem check
            startingBalancesFolio[j] = _token.balanceOf(address(folio));
            startingBalancesUser[j] = _token.balanceOf(address(user1));
        }

        // Redeem
        vm.startPrank(user1);
        vm.startSnapshotGas(redeemGasTag);
        folio.redeem(mintAmount / 2, user1, tokens, new uint256[](tokens.length));
        vm.stopSnapshotGas(redeemGasTag);

        // check balances
        assertEq(folio.balanceOf(user1), mintAmount / 2 - mintAmount / 2000, "wrong user1 balance");
        for (uint256 j = 0; j < tokens.length; j++) {
            IERC20 _token = IERC20(tokens[j]);

            uint256 tolerance = (p.decimals > 18) ? 10 ** (p.decimals - 18) : 1;

            assertApproxEqAbs(
                _token.balanceOf(address(folio)),
                startingBalancesFolio[j] - (amounts[j] / 2),
                tolerance,
                "wrong folio token balance"
            );

            assertApproxEqAbs(
                _token.balanceOf(user1),
                startingBalancesUser[j] + (amounts[j] / 2),
                tolerance,
                "wrong user token balance"
            );
        }
        vm.stopPrank();
    }

    function run_trading_scenario(TradingTestParams memory p) public {
        IERC20 sell = deployCoin("Sell Token", "SELL", p.sellDecimals);
        IERC20 buy = deployCoin("Buy Token", "BUY", p.buyDecimals);

        // Create and mint tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(sell);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = p.sellAmount;

        mintTokens(tokens[0], getActors(), amounts[0]);

        // deploy folio
        uint256 initialSupply = p.sellAmount;
        uint256 folioFee = MAX_FOLIO_FEE_ANNUALLY;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);
        _deployTestFolio(tokens, amounts, initialSupply, folioFee, 0, recipients);

        // approveTrade
        vm.prank(dao);
        folio.approveTrade(0, sell, buy, 0, MAX_EXCHANGE_RATE, 0, 0, MAX_TTL);

        // openTrade
        vm.prank(priceCurator);
        uint256 endPrice = p.price / MAX_PRICE_RANGE;
        folio.openTrade(0, p.price, endPrice > p.price ? endPrice : p.price);

        // sellAmount will be up to 1e36
        // buyAmount will be up to 1e54 and down to 1

        (, , , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);

        uint256 sellAmount = folio.lot(0, start);
        // getBid should work at both ends of auction
        uint256 highBuyAmount = folio.getBid(0, start, sellAmount); // should not revert
        assertLe(folio.getBid(0, start + 1, sellAmount), highBuyAmount, "buyAmount should be non-increasing");

        sellAmount = folio.lot(0, end);
        uint256 buyAmount = folio.getBid(0, end, sellAmount); // should not revert
        assertGt(buyAmount, 0, "lot is free");
        assertGe(folio.getBid(0, end - 1, sellAmount), buyAmount, "buyAmount should be non-increasing");

        // mint buy tokens to user1 and bid
        vm.warp(end);
        deal(address(buy), address(user1), buyAmount, true);
        vm.startPrank(user1);
        buy.approve(address(folio), buyAmount);
        folio.bid(0, sellAmount, buyAmount, false, bytes(""));
        vm.stopPrank();

        // check bal differences
        assertEq(sell.balanceOf(address(folio)), 0, "wrong sell bal");
        assertEq(buy.balanceOf(address(folio)), buyAmount, "wrong buy bal");
    }

    function run_fees_scenario(FeeTestParams memory p) public {
        // Create folio (tokens and decimals not relevant)
        address[] memory tokens = new address[](3);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        tokens[2] = address(MEME);
        uint256[] memory amounts = new uint256[](tokens.length);
        for (uint256 j = 0; j < tokens.length; j++) {
            amounts[j] = p.amount;
            mintTokens(tokens[j], getActors(), amounts[j]);
        }
        uint256 initialSupply = p.amount * 1e18;

        // Populate recipients
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](p.numFeeRecipients);
        uint96 feeReceiverShare = 1e18 / uint96(p.numFeeRecipients);
        for (uint256 i = 0; i < p.numFeeRecipients; i++) {
            recipients[i] = IFolio.FeeRecipient(address(uint160(i + 1)), feeReceiverShare);
        }
        _deployTestFolio(tokens, amounts, initialSupply, p.folioFee, 0, recipients);

        // set dao fee
        daoFeeRegistry.setTokenFeeNumerator(address(folio), p.daoFee);

        // fast forward, accumulate fees
        vm.warp(block.timestamp + p.timeLapse);
        vm.roll(block.number + 1000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();
        folio.distributeFees();

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = (pendingFeeShares * daoFeeNumerator + daoFeeDenominator - 1) / daoFeeDenominator;

        assertApproxEqAbs(folio.balanceOf(address(dao)), expectedDaoShares, p.numFeeRecipients, "wrong dao shares");

        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        for (uint256 i = 0; i < recipients.length; i++) {
            assertEq(
                folio.balanceOf(recipients[i].recipient),
                (remainingShares * feeReceiverShare) / 1e18,
                "wrong receiver shares"
            );
        }
    }
}
