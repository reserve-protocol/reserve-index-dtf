// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFolio} from "contracts/interfaces/IFolio.sol";
import {FolioLens} from "@periphery/FolioLens.sol";
import {AUCTION_WARMUP, D18, D27, MAX_AUCTION_LENGTH, MAX_TTL, MAX_WEIGHT} from "@utils/Constants.sol";

import "./base/BaseTest.sol";

contract FolioLensTest is BaseTest {
    FolioLens lens;

    function _setUp() public override {
        lens = new FolioLens();

        address[] memory assets = new address[](2);
        assets[0] = address(USDC);
        assets[1] = address(DAI);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;

        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](0);

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);
        (folio, proxyAdmin) = createFolio(
            assets, amounts, D18_TOKEN_10K, MAX_AUCTION_LENGTH, recipients, 0, 0, owner, dao, auctionLauncher
        );
        vm.stopPrank();
    }

    function test_getSpotWeights() public view {
        (address[] memory tokens, uint256[] memory weights) = lens.getSpotWeights(folio);

        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(USDC));
        assertEq(tokens[1], address(DAI));
        assertEq(weights[0], 1e15);
        assertEq(weights[1], D27);
    }

    function test_surplusesAndDeficits() public {
        _startBalancedRebalance();

        (address[] memory tokens, uint256[] memory surpluses, uint256[] memory deficits) =
            lens.surplusesAndDeficits(folio, D18, D18);

        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(USDC));
        assertEq(tokens[1], address(DAI));
        assertEq(surpluses[0], 0);
        assertEq(surpluses[1], 0);
        assertEq(deficits[0], 0);
        assertEq(deficits[1], 0);
    }

    function test_getAllBids() public {
        _startSellUsdcRebalance();

        vm.prank(auctionLauncher);
        folio.openAuction(1, _tokens(), _sellUsdcWeights(), _prices(), _limits(), MAX_AUCTION_LENGTH);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        FolioLens.SingleBid[] memory bids = lens.getAllBids(folio, 0);

        assertEq(bids.length, 1);
        assertEq(bids[0].sellToken, address(USDC));
        assertEq(bids[0].buyToken, address(DAI));
        assertGt(bids[0].sellAmount, 0);
        assertGt(bids[0].bidAmount, 0);
        assertGt(bids[0].price, 0);
    }

    function _startBalancedRebalance() private {
        startRebalance(folio, _rebalanceTokens(_balancedWeights()), _limits(), 0, MAX_TTL);
    }

    function _startSellUsdcRebalance() private {
        startRebalance(folio, _rebalanceTokens(_sellUsdcWeights()), _limits(), 0, MAX_TTL);
    }

    function _rebalanceTokens(IFolio.WeightRange[] memory weights)
        private
        view
        returns (IFolio.TokenRebalanceParams[] memory tokens)
    {
        address[] memory assets = _tokens();
        IFolio.PriceRange[] memory prices = _prices();

        tokens = new IFolio.TokenRebalanceParams[](2);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
    }

    function _tokens() private view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
    }

    function _balancedWeights() private pure returns (IFolio.WeightRange[] memory weights) {
        weights = new IFolio.WeightRange[](2);
        weights[0] = IFolio.WeightRange({low: 1e15, spot: 1e15, high: 1e15});
        weights[1] = IFolio.WeightRange({low: D27, spot: D27, high: D27});
    }

    function _sellUsdcWeights() private pure returns (IFolio.WeightRange[] memory weights) {
        weights = new IFolio.WeightRange[](2);
        weights[0] = IFolio.WeightRange({low: 0, spot: 0, high: 0});
        weights[1] = IFolio.WeightRange({low: MAX_WEIGHT, spot: MAX_WEIGHT, high: MAX_WEIGHT});
    }

    function _prices() private pure returns (IFolio.PriceRange[] memory prices) {
        prices = new IFolio.PriceRange[](2);
        prices[0] = IFolio.PriceRange({low: 1e20, high: 1e22});
        prices[1] = IFolio.PriceRange({low: 1e8, high: 1e10});
    }

    function _limits() private pure returns (IFolio.RebalanceLimits memory) {
        return IFolio.RebalanceLimits({low: D18, spot: D18, high: D18});
    }
}
