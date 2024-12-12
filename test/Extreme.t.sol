// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio, MAX_AUCTION_LENGTH, MAX_TRADE_DELAY, MAX_FEE } from "contracts/Folio.sol";
import "./base/BaseExtremeTest.sol";

contract ExtremeTest is BaseExtremeTest {
    function _deployTestFolio(address[] memory _tokens, uint256[] memory _amounts, uint256 initialSupply) public {
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);
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
        folio = createFolio(
            _tokens,
            _amounts,
            initialSupply,
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            100,
            owner,
            dao,
            priceCurator
        );
        vm.stopSnapshotGas(deployGasTag);
        vm.stopPrank();
    }

    function test_mint_redeem_extreme() public {
        // Process all test combinations
        for (uint256 i; i < testParameters.length; i++) {
            run_mint_redeem_scenario(testParameters[i]);
        }
    }

    function run_mint_redeem_scenario(TestParam memory p) public {
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
            mintTokens(tokens[j], getActors(), amounts[j]);
        }

        // deploy folio
        uint256 initialSupply = p.amount * 1e18;
        _deployTestFolio(tokens, amounts, initialSupply);

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
        vm.startSnapshotGas(redeemGasTag);
        folio.redeem(mintAmount / 2, user1);
        vm.stopSnapshotGas(redeemGasTag);

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
