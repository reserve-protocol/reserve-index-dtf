// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IFolio } from "@interfaces/IFolio.sol";
import { Folio } from "@src/Folio.sol";
import { MAX_AUCTION_LENGTH, MAX_TVL_FEE, MAX_TTL, MAX_WEIGHT, MAX_TOKEN_PRICE, MAX_TOKEN_PRICE_RANGE, RESTRICTED_AUCTION_BUFFER } from "@utils/Constants.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import "./base/BaseExtremeTest.sol";

contract ExtremeTest is BaseExtremeTest {
    IFolio.WeightRange internal REMOVE = IFolio.WeightRange({ low: 0, spot: 0, high: 0 });
    IFolio.WeightRange internal BUY = IFolio.WeightRange({ low: MAX_WEIGHT, spot: MAX_WEIGHT, high: MAX_WEIGHT });

    function _deployTestFolio(
        address[] memory _tokens,
        uint256[] memory _amounts,
        uint256 initialSupply,
        uint256 tvlFee,
        uint256 mintFee,
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
            MAX_AUCTION_LENGTH,
            recipients,
            tvlFee,
            mintFee,
            owner,
            dao,
            auctionLauncher
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

    function test_staking_rewards_extreme() public {
        deployCoins();

        // Process all test combinations
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < stkRewardsTestParams.length; i++) {
            run_staking_rewards_scenario(stkRewardsTestParams[i]);
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
        uint256 tvlFee = MAX_TVL_FEE;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);
        _deployTestFolio(tokens, amounts, initialSupply, tvlFee, 0, recipients);

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
        folio.mint(mintAmount, user1, 0);
        vm.stopSnapshotGas(mintGasTag);
        vm.stopPrank();

        // check balances
        assertEq(folio.balanceOf(user1), mintAmount - (mintAmount * 3) / 2000, "wrong user1 balance");
        for (uint256 j = 0; j < tokens.length; j++) {
            {}
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
        assertEq(folio.balanceOf(user1), mintAmount / 2 - (mintAmount * 3) / 2000, "wrong user1 balance");
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

    function run_trading_scenario(RebalancingTestParams memory p) public {
        IERC20 sell = deployCoin("Sell Token", "SELL", p.sellDecimals);
        IERC20 buy = deployCoin("Buy Token", "BUY", p.buyDecimals);

        // deploy folio
        {
            // Create and mint tokens
            address[] memory tokens = new address[](1);
            tokens[0] = address(sell);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = p.sellAmount;

            mintTokens(tokens[0], getActors(), amounts[0]);

            uint256 initialSupply = p.sellAmount;
            uint256 tvlFee = MAX_TVL_FEE;
            IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
            recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
            recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);
            _deployTestFolio(tokens, amounts, initialSupply, tvlFee, 0, recipients);
        }

        // startRebalance
        {
            address[] memory assets = new address[](2);
            IFolio.WeightRange[] memory weights = new IFolio.WeightRange[](2);
            IFolio.PriceRange[] memory prices = new IFolio.PriceRange[](2);
            IFolio.RebalanceLimits memory limits = IFolio.RebalanceLimits({
                low: p.testLimits,
                spot: p.testLimits,
                high: p.testLimits
            });
            assets[0] = address(sell);
            assets[1] = address(buy);
            weights[0] = REMOVE;
            weights[1] = BUY;

            {
                uint256 highSellPrice = p.sellTokenPrice * MAX_TOKEN_PRICE_RANGE;
                uint256 lowSellPrice = p.sellTokenPrice;
                if (highSellPrice > MAX_TOKEN_PRICE) {
                    highSellPrice = MAX_TOKEN_PRICE;
                    lowSellPrice = highSellPrice / MAX_TOKEN_PRICE_RANGE;
                }

                prices[0] = IFolio.PriceRange(lowSellPrice, highSellPrice);
            }

            {
                uint256 highBuyPrice = p.buyTokenPrice * MAX_TOKEN_PRICE_RANGE;
                uint256 lowBuyPrice = p.buyTokenPrice;
                if (highBuyPrice > MAX_TOKEN_PRICE) {
                    highBuyPrice = MAX_TOKEN_PRICE;
                    lowBuyPrice = highBuyPrice / MAX_TOKEN_PRICE_RANGE;
                }

                prices[1] = IFolio.PriceRange(lowBuyPrice, highBuyPrice);
            }

            vm.prank(dao);
            folio.startRebalance(assets, weights, prices, limits, 0, MAX_TTL);
        }

        // openAuctionUnrestricted
        vm.warp(block.timestamp + RESTRICTED_AUCTION_BUFFER);
        folio.openAuctionUnrestricted(1);

        (, uint256 start, uint256 end) = folio.auctions(0);

        // should quote at both ends

        vm.warp(start);
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, sell, buy, type(uint256).max);
        vm.warp(end);
        (sellAmount, buyAmount, ) = folio.getBid(0, sell, buy, type(uint256).max);

        if (buyAmount != 0) {
            // mint buy tokens to user1 and bid
            deal(address(buy), address(user1), buyAmount, true);
            vm.startPrank(user1);
            buy.approve(address(folio), buyAmount);
            folio.bid(0, sell, buy, sellAmount, buyAmount, false, bytes(""));
        }
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
        _deployTestFolio(tokens, amounts, initialSupply, p.tvlFee, 0, recipients);

        // set dao fee
        daoFeeRegistry.setTokenFeeNumerator(address(folio), p.daoFee);

        // fast forward, accumulate fees
        vm.warp(block.timestamp + p.timeLapse);
        vm.roll(block.number + 1000);
        folio.distributeFees();
    }

    function run_staking_rewards_scenario(StakingRewardsTestParams memory p) public {
        string memory pokeGasTag = string.concat(
            "poke(",
            vm.toString(p.numTokens),
            " tokens, ",
            vm.toString(p.decimals),
            " decimals, ",
            vm.toString(p.rewardAmount),
            " rewardAmount, ",
            vm.toString(p.rewardHalfLife),
            " rewardHalfLife, ",
            vm.toString(p.mintAmount),
            " mintAmount)"
        );
        string memory claimRewardsGasTag = string.concat(
            "claimRewards(",
            vm.toString(p.numTokens),
            " tokens, ",
            vm.toString(p.decimals),
            " decimals, ",
            vm.toString(p.rewardAmount),
            " rewardAmount, ",
            vm.toString(p.rewardHalfLife),
            " rewardHalfLife, ",
            vm.toString(p.mintAmount),
            " mintAmount)"
        );

        IERC20 token = deployCoin("Mock Token", "TKN", 18); // mock

        StakingVault vault = new StakingVault(
            "Staked Test Token",
            "sTEST",
            IERC20(address(token)),
            address(this),
            p.rewardHalfLife,
            0
        );

        // Create reward tokens
        address[] memory rewardTokens = new address[](p.numTokens);
        for (uint256 j = 0; j < p.numTokens; j++) {
            rewardTokens[j] = address(
                deployCoin(
                    string(abi.encodePacked("Reward Token", j)),
                    string(abi.encodePacked("RWRDTKN", j)),
                    p.decimals
                )
            );
            vault.addRewardToken(rewardTokens[j]);
        }

        // Deposit
        uint256 mintAmount = p.mintAmount;
        MockERC20(address(token)).mint(address(this), mintAmount);
        token.approve(address(vault), mintAmount);
        vault.deposit(mintAmount, user1);

        // advance time
        vm.warp(block.timestamp + 1);

        // Mint rewards
        for (uint256 j = 0; j < p.numTokens; j++) {
            MockERC20(rewardTokens[j]).mint(address(vault), p.rewardAmount);
        }
        vm.startSnapshotGas(pokeGasTag);
        vault.poke();
        vm.stopSnapshotGas(pokeGasTag);

        // advance 1 half life
        vm.warp(block.timestamp + p.rewardHalfLife);

        // Claim rewards
        vm.prank(user1);
        vault.claimRewards(rewardTokens);

        // one half life has passed; 1 = 0.5 ^ 1 = 50%
        uint256 expectedRewards = p.rewardAmount / 2;

        for (uint256 j = 0; j < p.numTokens; j++) {
            MockERC20 reward = MockERC20(rewardTokens[j]);
            assertApproxEqRel(reward.balanceOf(user1), expectedRewards, 1e14);
        }

        // advance 2 half lives
        vm.warp(block.timestamp + p.rewardHalfLife * 2);

        // Claim rewards
        vm.prank(user1);
        vm.startSnapshotGas(claimRewardsGasTag);
        vault.claimRewards(rewardTokens);
        vm.stopSnapshotGas();

        // three half lives have passed: 1 - 0.5 ^ 3 = 87.5%
        expectedRewards = (p.rewardAmount * 7) / 8;

        for (uint256 j = 0; j < p.numTokens; j++) {
            MockERC20 reward = MockERC20(rewardTokens[j]);
            assertApproxEqRel(reward.balanceOf(user1), expectedRewards, 1e14);
        }
    }
}
