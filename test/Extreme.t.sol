// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio } from "contracts/Folio.sol";
import "./base/BaseExtremeTest.sol";

contract ExtremeTest is BaseExtremeTest {
    function _deployTestFolio(address[] memory _tokens, uint256[] memory _amounts, uint256 initialSupply) public {
        // 1% demurrage fee
        IFolio.DemurrageRecipient[] memory recipients = new IFolio.DemurrageRecipient[](2);
        recipients[0] = IFolio.DemurrageRecipient(owner, 9000);
        recipients[1] = IFolio.DemurrageRecipient(feeReceiver, 1000);

        // create folio
        vm.startPrank(owner);
        for (uint256 i = 0; i < _tokens.length; i++) {
            IERC20(_tokens[i]).approve(address(folioFactory), type(uint256).max);
        }
        folio = Folio(
            folioFactory.createFolio("Test Folio", "TFOLIO", _tokens, _amounts, initialSupply, 100, recipients)
        );
        vm.stopPrank();
    }

    function test_mint_redeem_extreme() public {
        // Process all test combinations
        for (uint256 i; i < testParameters.length; i++) {
            TestParam storage p = testParameters[i];

            // Create and mint tokens
            address[] memory tokens = new address[](p.numTokens);
            uint256[] memory amounts = new uint256[](p.numTokens);
            for (uint256 j = 0; j < p.numTokens; j++) {
                tokens[j] = address(
                    deployCoin(string(abi.encodePacked("Token", j)), string(abi.encodePacked("TKN", j)), p.decimals)
                );
                amounts[j] = p.amount * (10 ** p.decimals);
                mintTokens(tokens[j], getActors(), amounts[j]);
            }

            // deploy folio
            uint256 initialSupply = p.amount * 1e18;
            _deployTestFolio(tokens, amounts, initialSupply);

            // check deployment
            assertEq(folio.name(), "Test Folio", "wrong name");
            assertEq(folio.symbol(), "TFOLIO", "wrong symbol");
            assertEq(folio.decimals(), 18, "wrong decimals");
            assertEq(folio.totalSupply(), initialSupply, "wrong total supply");
            assertEq(folio.balanceOf(owner), initialSupply, "wrong owner balance");
            assertEq(folio.assets().length, p.numTokens, "wrong assets length");
            for (uint256 j = 0; j < p.numTokens; j++) {
                assertEq(folio.assets()[j], tokens[j], "wrong asset");
                assertEq(IERC20(tokens[j]).balanceOf(address(folio)), amounts[j], "wrong folio token balance");
            }
            assertEq(folio.demurrageFee(), 100, "wrong demurrage fee");
            (address r1, uint256 bps1) = folio.demurrageRecipients(0);
            assertEq(r1, owner, "wrong first recipient");
            assertEq(bps1, 9000, "wrong first recipient bps");
            (address r2, uint256 bps2) = folio.demurrageRecipients(1);
            assertEq(r2, feeReceiver, "wrong second recipient");
            assertEq(bps2, 1000, "wrong second recipient bps");

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
            folio.mint(mintAmount, user1);
            vm.stopPrank();

            // check balances
            assertEq(folio.balanceOf(user1), mintAmount, "wrong user1 balance");
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
            folio.redeem(mintAmount / 2, user1, user1);

            // check balances
            assertEq(folio.balanceOf(user1), mintAmount / 2, "wrong user1 balance");
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
    }
}
