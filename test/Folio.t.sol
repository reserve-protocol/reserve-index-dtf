// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio } from "contracts/Folio.sol";
import "./base/BaseTest.sol";

contract FolioTest is BaseTest {
    function _deployTestFolio() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        tokens[2] = address(MEME);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        amounts[2] = D27_TOKEN_10K;
        IFolio.DemurrageRecipient[] memory recipients = new IFolio.DemurrageRecipient[](1);
        recipients[0] = IFolio.DemurrageRecipient(owner, 10000);
        // 1% demurrage fee
        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        DAI.approve(address(folioFactory), type(uint256).max);
        MEME.approve(address(folioFactory), type(uint256).max);
        folio = Folio(
            folioFactory.createFolio(
                "Test Folio",
                "TFOLIO",
                tokens,
                amounts,
                D18_TOKEN_10K,
                100,
                recipients,
                address(0)
            )
        );
        vm.stopPrank();
    }

    function test_deployment() public {
        _deployTestFolio();
        assertEq(folio.name(), "Test Folio");
        assertEq(folio.symbol(), "TFOLIO");
        assertEq(folio.decimals(), 18);
        assertEq(folio.totalSupply(), 1e18 * 10000);
        assertEq(folio.balanceOf(owner), 1e18 * 10000);
        assertEq(folio.assets().length, 3);
        assertEq(folio.assets()[0], address(USDC));
        assertEq(folio.assets()[1], address(DAI));
        assertEq(folio.assets()[2], address(MEME));
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K);
        assertEq(DAI.balanceOf(address(folio)), D18_TOKEN_10K);
        assertEq(MEME.balanceOf(address(folio)), D27_TOKEN_10K);
        assertEq(folio.demurrageFee(), 100);
        (address recipient, uint256 bps) = folio.demurrageRecipients(0);
        assertEq(recipient, owner);
        assertEq(bps, 10000);
    }

    function test_mint() public {
        _deployTestFolio();
        assertEq(folio.balanceOf(user1), 0);
        uint256 startingUSDCBalance = USDC.balanceOf(address(folio));
        uint256 startingDAIBalance = DAI.balanceOf(address(folio));
        uint256 startingMEMEBalance = MEME.balanceOf(address(folio));
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);
        folio.mint(1e22, user1);
        assertEq(folio.balanceOf(user1), 1e22);
        assertApproxEqAbs(USDC.balanceOf(address(folio)), startingUSDCBalance + D6_TOKEN_10K, 1);
        assertApproxEqAbs(DAI.balanceOf(address(folio)), startingDAIBalance + D18_TOKEN_10K, 1);
        assertApproxEqAbs(MEME.balanceOf(address(folio)), startingMEMEBalance + D27_TOKEN_10K, 1e9);
    }

    function test_redeem() public {
        _deployTestFolio();
        assertEq(folio.balanceOf(user1), 0);
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
        assertApproxEqAbs(USDC.balanceOf(address(folio)), startingUSDCBalanceFolio - D6_TOKEN_10K / 2, 1);
        assertApproxEqAbs(DAI.balanceOf(address(folio)), startingDAIBalanceFolio - D18_TOKEN_10K / 2, 1);
        assertApproxEqAbs(MEME.balanceOf(address(folio)), startingMEMEBalanceFolio - D27_TOKEN_10K / 2, 1e9);
        assertApproxEqAbs(USDC.balanceOf(user1), startingUSDCBalanceAlice + D6_TOKEN_10K / 2, 1);
        assertApproxEqAbs(DAI.balanceOf(user1), startingDAIBalanceAlice + D18_TOKEN_10K / 2, 1);
        assertApproxEqAbs(MEME.balanceOf(user1), startingMEMEBalanceAlice + D27_TOKEN_10K / 2, 1e9);
    }
}
