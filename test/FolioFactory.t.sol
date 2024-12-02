// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { FolioFactory } from "contracts/FolioFactory.sol";
import "./base/BaseTest.sol";

contract FolioFactoryTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;

    function test_createFolio() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9000);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1000);

        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        DAI.approve(address(folioFactory), type(uint256).max);
        folio = Folio(
            folioFactory.createFolio("Test Folio", "TFOLIO", tokens, amounts, INITIAL_SUPPLY, recipients, 100, owner)
        );

        vm.stopPrank();
        assertEq(folio.name(), "Test Folio", "wrong name");
        assertEq(folio.symbol(), "TFOLIO", "wrong symbol");
        assertEq(folio.decimals(), 18, "wrong decimals");
        assertEq(folio.totalSupply(), 1e18 * 10000, "wrong total supply");
        assertEq(folio.balanceOf(owner), 1e18 * 10000, "wrong owner balance");
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 2, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K, "wrong folio usdc balance");
        assertEq(DAI.balanceOf(address(folio)), D18_TOKEN_10K, "wrong folio dai balance");
        assertEq(folio.folioFee(), 100, "wrong folio fee");
        (address r1, uint256 bps1) = folio.feeRecipients(0);
        assertEq(r1, owner, "wrong first recipient");
        assertEq(bps1, 9000, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.feeRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 1000, "wrong second recipient bps");
    }

    function test_cannotCreateFolioWithInvalidLength() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = D6_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9000);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1000);

        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        DAI.approve(address(folioFactory), type(uint256).max);
        vm.expectRevert(FolioFactory.FolioFactory__LengthMismatch.selector);
        folioFactory.createFolio("Test Folio", "TFOLIO", tokens, amounts, INITIAL_SUPPLY, recipients, 100, owner);
        vm.stopPrank();
    }

    function test_cannotCreateFolioWithInvalidAsset() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(0); // invalid
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9000);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1000);

        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        vm.expectRevert(); // when trying to transfer tokens
        folioFactory.createFolio("Test Folio", "TFOLIO", tokens, amounts, INITIAL_SUPPLY, recipients, 100, owner);
        vm.stopPrank();
    }

    function test_cannotCreateFolioWithZeroAmount() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = 0;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9000);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1000);

        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IFolio.Folio__InvalidAssetAmount.selector, address(DAI)));
        folioFactory.createFolio("Test Folio", "TFOLIO", tokens, amounts, INITIAL_SUPPLY, recipients, 100, owner);
        vm.stopPrank();
    }
}
