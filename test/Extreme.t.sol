// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IFolio } from "@interfaces/IFolio.sol";
import { Folio } from "@src/Folio.sol";
import { D18, D27, MAX_AUCTION_LENGTH, MAX_TVL_FEE, MAX_TTL, MAX_LIMIT, MAX_TOKEN_PRICE, MAX_TOKEN_PRICE_RANGE, RESTRICTED_AUCTION_BUFFER, MAX_TOKEN_BALANCE } from "@utils/Constants.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import { MathLib } from "@utils/MathLib.sol";
import "./base/BaseExtremeTest.sol";

contract ExtremeTest is BaseExtremeTest {
    IFolio.BasketRange internal FULL_SELL = IFolio.BasketRange(0, 0, 0);
    IFolio.BasketRange internal FULL_BUY = IFolio.BasketRange(MAX_LIMIT, MAX_LIMIT, MAX_LIMIT);

    IFolio.Prices internal ZERO_PRICE = IFolio.Prices(0, 0);

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
            IFolio.BasketRange[] memory limits = new IFolio.BasketRange[](2);
            IFolio.Prices[] memory prices = new IFolio.Prices[](2);
            assets[0] = address(sell);
            assets[1] = address(buy);
            limits[0] = FULL_SELL;
            limits[1] = FULL_BUY;
            prices[0] = IFolio.Prices(
                (p.sellTokenPrice + MAX_TOKEN_PRICE_RANGE - 1) / MAX_TOKEN_PRICE_RANGE,
                p.sellTokenPrice
            );
            prices[1] = IFolio.Prices(
                (p.buyTokenPrice + MAX_TOKEN_PRICE_RANGE - 1) / MAX_TOKEN_PRICE_RANGE,
                p.buyTokenPrice
            );

            vm.prank(dao);
            folio.startRebalance(assets, limits, prices, 0, MAX_TTL);
        }

        // openAuctionUnrestricted
        vm.warp(block.timestamp + RESTRICTED_AUCTION_BUFFER);
        folio.openAuctionUnrestricted(sell, buy);

        (, , , , , uint256 startPrice, uint256 endPrice, uint256 start, uint256 end) = folio.auctions(0);

        uint256 totalSupply = folio.totalSupply();

        // check that start >= start + 1
        uint256 startBidAmount = _getBidAmount(sell, buy, totalSupply, startPrice, endPrice, start, end, start);
        uint256 endBidAmount = _getBidAmount(sell, buy, totalSupply, startPrice, endPrice, start, end, start + 1);

        if (startBidAmount > 0 && endBidAmount > 0) {
            // should not revert
            (, , uint256 actualStartPrice) = folio.getBid(0, start, type(uint256).max);

            // getBid should work at start and start + 1, and they should be relatively ordered
            (, , uint256 actualEndPrice) = folio.getBid(0, start + 1, type(uint256).max);
            assertLe(actualEndPrice, actualStartPrice, "price should be non-increasing");
        }

        // check that end - 1 > end as well
        startBidAmount = _getBidAmount(sell, buy, totalSupply, startPrice, endPrice, start, end, end - 1);
        endBidAmount = _getBidAmount(sell, buy, totalSupply, startPrice, endPrice, start, end, end);

        if (startBidAmount > 0 && endBidAmount > 0) {
            // should not revert
            (, , uint256 actualStartPrice) = folio.getBid(0, end - 1, type(uint256).max);

            // getBid should work at end - 1 and end, and they should be relatively ordered
            (uint256 sellAmount2, uint256 buyAmount2, uint256 actualEndPrice) = folio.getBid(0, end, type(uint256).max);
            assertLe(actualEndPrice, actualStartPrice, "price should be non-increasing");

            // mint buy tokens to user1 and bid
            vm.warp(end);
            deal(address(buy), address(user1), buyAmount2, true);
            vm.startPrank(user1);
            buy.approve(address(folio), buyAmount2);
            folio.bid(0, sellAmount2, buyAmount2, false, bytes(""));
            vm.stopPrank();
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

    /// ==== Internal ====

    /// Returns 0 where the actual getBid() function would revert
    /// @return bidAmount {buyTok}
    function _getBidAmount(
        IERC20 sell,
        IERC20 buy,
        uint256 totalSupply,
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 endTime,
        uint256 timestamp
    ) internal view returns (uint256 bidAmount) {
        // D27{buyTok/sellTok}
        uint256 price = _price(startPrice, endPrice, startTime, endTime, timestamp);

        // {sellTok} = D27{sellTok/share} * {share} / D27
        uint256 sellLimitBal = Math.mulDiv(0, totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = sell.balanceOf(address(folio)) > sellLimitBal
            ? sell.balanceOf(address(folio)) - sellLimitBal
            : 0;

        // {buyTok} = D27{buyTok/share} * {share} / D27
        uint256 buyLimitBal = Math.mulDiv(MAX_LIMIT, totalSupply, D27, Math.Rounding.Floor);
        uint256 buyAvailable = buy.balanceOf(address(folio)) < buyLimitBal
            ? buyLimitBal - buy.balanceOf(address(folio))
            : 0;

        buyAvailable = Math.min(buyAvailable, MAX_TOKEN_BALANCE);

        // {sellTok} = {buyTok} * D27 / D27{buyTok/sellTok}
        uint256 sellAvailableFromBuy = Math.mulDiv(buyAvailable, D27, price, Math.Rounding.Floor);
        sellAvailable = Math.min(sellAvailable, sellAvailableFromBuy);

        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        bidAmount = Math.mulDiv(sellAvailable, price, D27, Math.Rounding.Ceil);
    }

    /// @return p D27{buyTok/sellTok}
    function _price(
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 endTime,
        uint256 timestamp
    ) internal pure returns (uint256 p) {
        // ensure auction is ongoing
        require(timestamp >= startTime && timestamp <= endTime, IFolio.Folio__AuctionNotOngoing());

        if (timestamp == startTime) {
            return startPrice;
        }
        if (timestamp == endTime) {
            return endPrice;
        }

        uint256 elapsed = timestamp - startTime;
        uint256 auctionLength = endTime - startTime;

        // D18{1}
        // k = ln(P_0 / P_t) / t
        uint256 k = MathLib.ln(Math.mulDiv(startPrice, D18, endPrice)) / auctionLength;

        // P_t = P_0 * e ^ -kt
        // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
        p = Math.mulDiv(startPrice, MathLib.exp(-1 * int256(k * elapsed)), D18);
        if (p < endPrice) {
            p = endPrice;
        }
    }
}
