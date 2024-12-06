// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { MAX_AUCTION_LENGTH, MAX_TRADE_DELAY } from "contracts/Folio.sol";
import { FolioFactory, IFolioFactory } from "contracts/deployer/FolioFactory.sol";
import "./base/BaseTest.sol";

contract FolioFactoryTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;

    function test_constructor() public {
        FolioFactory folioFactory = new FolioFactory(address(daoFeeRegistry), address(0));
        assertEq(address(folioFactory.daoFeeRegistry()), address(daoFeeRegistry));
        assertNotEq(address(folioFactory.folioImplementation()), address(0));
    }

    function test_createFolio() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1e17);

        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        DAI.approve(address(folioFactory), type(uint256).max);
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
                100,
                owner
            )
        );

        vm.stopPrank();
        assertEq(folio.name(), "Test Folio", "wrong name");
        assertEq(folio.symbol(), "TFOLIO", "wrong symbol");
        assertEq(folio.decimals(), 18, "wrong decimals");
        assertEq(folio.auctionLength(), MAX_AUCTION_LENGTH, "wrong auction length");
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
        assertEq(bps1, 9e17, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.feeRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 1e17, "wrong second recipient bps");
    }

    function test_cannotCreateFolioWithLengthMismatch() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = D6_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1e17);

        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        DAI.approve(address(folioFactory), type(uint256).max);
        vm.expectRevert(IFolioFactory.FolioFactory__LengthMismatch.selector);
        folioFactory.createFolio(
            "Test Folio",
            "TFOLIO",
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            tokens,
            amounts,
            INITIAL_SUPPLY,
            recipients,
            100,
            owner
        );
        vm.stopPrank();
    }

    function test_cannotCreateFolioWithNoAssets() public {
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1e17);

        vm.startPrank(owner);
        vm.expectRevert(IFolioFactory.FolioFactory__EmptyAssets.selector);
        folioFactory.createFolio(
            "Test Folio",
            "TFOLIO",
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            tokens,
            amounts,
            1,
            recipients,
            100,
            owner
        );
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
        recipients[0] = IFolio.FeeRecipient(owner, 9e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1e17);

        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        vm.expectRevert(); // when trying to transfer tokens
        folioFactory.createFolio(
            "Test Folio",
            "TFOLIO",
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            tokens,
            amounts,
            INITIAL_SUPPLY,
            recipients,
            100,
            owner
        );
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
        recipients[0] = IFolio.FeeRecipient(owner, 9e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1e17);

        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IFolio.Folio__InvalidAssetAmount.selector, address(DAI)));
        folioFactory.createFolio(
            "Test Folio",
            "TFOLIO",
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            tokens,
            amounts,
            INITIAL_SUPPLY,
            recipients,
            100,
            owner
        );
        vm.stopPrank();
    }

    function test_cannotCreateFolioWithNoApprovalOrBalance() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = D6_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1e17);

        vm.startPrank(owner);
        vm.expectRevert(); // no approval
        folioFactory.createFolio(
            "Test Folio",
            "TFOLIO",
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            tokens,
            amounts,
            INITIAL_SUPPLY,
            recipients,
            100,
            owner
        );
        vm.stopPrank();

        // with approval but no balance
        vm.startPrank(user1);
        USDC.transfer(owner, USDC.balanceOf(user1));
        USDC.approve(address(folioFactory), type(uint256).max);
        vm.expectRevert(); // no balance
        folioFactory.createFolio(
            "Test Folio",
            "TFOLIO",
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            tokens,
            amounts,
            INITIAL_SUPPLY,
            recipients,
            100,
            owner
        );
        vm.stopPrank();
    }

    function test_cannotCreateFolioWithInvalidAuctionLength() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = D6_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1e17);

        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);

        vm.expectRevert(IFolio.Folio__InvalidAuctionLength.selector); // below min
        folioFactory.createFolio(
            "Test Folio",
            "TFOLIO",
            MAX_TRADE_DELAY,
            1,
            tokens,
            amounts,
            INITIAL_SUPPLY,
            recipients,
            100,
            owner
        );

        vm.expectRevert(IFolio.Folio__InvalidAuctionLength.selector); // above max
        folioFactory.createFolio(
            "Test Folio",
            "TFOLIO",
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH + 1,
            tokens,
            amounts,
            INITIAL_SUPPLY,
            recipients,
            100,
            owner
        );

        vm.stopPrank();
    }

    function test_cannotCreateFolioWithInvalidTradeDelay() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = D6_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9e17);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1e17);

        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);

        vm.expectRevert(IFolio.Folio__InvalidTradeDelay.selector); // above max
        folioFactory.createFolio(
            "Test Folio",
            "TFOLIO",
            MAX_TRADE_DELAY + 1,
            MAX_AUCTION_LENGTH,
            tokens,
            amounts,
            INITIAL_SUPPLY,
            recipients,
            100,
            owner
        );

        vm.stopPrank();
    }
}
