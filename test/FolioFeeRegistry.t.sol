// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { IFolioFeeRegistry } from "contracts/interfaces/IFolioFeeRegistry.sol";
import { FolioFeeRegistry, FEE_DENOMINATOR, MAX_FEE_NUMERATOR } from "contracts/FolioFeeRegistry.sol";
import { MAX_AUCTION_LENGTH, MAX_FEE } from "contracts/Folio.sol";
import "./base/BaseTest.sol";

contract FolioFeeRegistryTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;

    function _testSetup() public virtual override {
        _testSetupBefore();
        _testSetupAfter();

        _deployTestFolio();
    }

    function _deployTestFolio() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 9000);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 1000);

        // 50% folio fee annually
        vm.startPrank(owner);
        USDC.approve(address(folioFactory), type(uint256).max);
        DAI.approve(address(folioFactory), type(uint256).max);
        folio = Folio(
            folioFactory.createFolio(
                "Test Folio",
                "TFOLIO",
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
        folio.grantRole(folio.PRICE_CURATOR(), dao);
        folio.grantRole(folio.PRICE_CURATOR(), priceCurator);
        vm.stopPrank();
    }

    function test_constructor() public {
        FolioFeeRegistry folioFeeRegistry = new FolioFeeRegistry(IRoleRegistry(address(roleRegistry)), dao);
        assertEq(address(folioFeeRegistry.roleRegistry()), address(roleRegistry));
        (address recipient, uint256 feeNumerator, uint256 feeDenominator) = folioFeeRegistry.getFeeDetails(
            address(folio)
        );
        assertEq(recipient, dao);
        assertEq(feeNumerator, 0); // no fee numerator set yet
        assertEq(feeDenominator, FEE_DENOMINATOR);
    }

    function test_cannotCreateFeeRegistryWithInvalidRoleRegistry() public {
        vm.expectRevert(IFolioFeeRegistry.FolioFeeRegistry__InvalidRoleRegistry.selector);
        new FolioFeeRegistry(IRoleRegistry(address(0)), dao);
    }

    function test_setFeeRecipient() public {
        _deployTestFolio();
        address recipient;
        (recipient, , ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(recipient, dao);

        daoFeeRegistry.setFeeRecipient(user2);

        (recipient, , ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(recipient, user2);
    }

    function test_cannotSetFeeRecipientIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert(IFolioFeeRegistry.FolioFeeRegistry__InvalidCaller.selector);
        daoFeeRegistry.setFeeRecipient(user2);
    }

    function test_cannotSetFeeRecipientWithInvalidAddress() public {
        vm.expectRevert(IFolioFeeRegistry.FolioFeeRegistry__InvalidFeeRecipient.selector);
        daoFeeRegistry.setFeeRecipient(address(0));
    }

    function test_cannotSetFeeRecipientIfAlreadySet() public {
        vm.expectRevert(IFolioFeeRegistry.FolioFeeRegistry__FeeRecipientAlreadySet.selector);
        daoFeeRegistry.setFeeRecipient(dao);
    }

    function test_setDefaultFeeNumerator() public {
        _deployTestFolio();
        uint256 numerator;
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0);

        daoFeeRegistry.setDefaultFeeNumerator(10_00);

        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 10_00);
    }

    function test_cannotSetDefaultTokenFeeNumeratorIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert(IFolioFeeRegistry.FolioFeeRegistry__InvalidCaller.selector);
        daoFeeRegistry.setDefaultFeeNumerator(10_00);
    }

    function test_cannotSetDefaultFeeNumeratorWithInvalidValue() public {
        vm.expectRevert(IFolioFeeRegistry.FolioFeeRegistry__InvalidFeeNumerator.selector);
        daoFeeRegistry.setDefaultFeeNumerator(MAX_FEE_NUMERATOR + 1);
    }

    function test_setTokenFeeNumerator() public {
        _deployTestFolio();
        uint256 numerator;
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0);

        daoFeeRegistry.setTokenFeeNumerator(address(folio), 10_00);

        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 10_00);
    }

    function test_cannotSetTokenFeeNumeratorIfNotOwner() public {
        vm.prank(user2);
        vm.expectRevert(IFolioFeeRegistry.FolioFeeRegistry__InvalidCaller.selector);
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 10_00);
    }

    function test_cannotSetTokenFeeNumeratorWithInvalidValue() public {
        vm.expectRevert(IFolioFeeRegistry.FolioFeeRegistry__InvalidFeeNumerator.selector);
        daoFeeRegistry.setTokenFeeNumerator(address(folio), MAX_FEE_NUMERATOR + 1);
    }

    function test_usesDefaultFeeNumeratorOnlyWhenTokenNumeratorIsNotSet() public {
        _deployTestFolio();
        uint256 numerator;
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0); // default

        // set new value for default fee numerator
        daoFeeRegistry.setDefaultFeeNumerator(5_00);

        // still using default
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 5_00);

        // set token fee numerator
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 10_00);

        // Token fee numerator overrides default
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 10_00);
    }

    function test_resetTokenFee() public {
        _deployTestFolio();
        uint256 numerator;

        // set token fee numerator
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 10_00);
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 10_00);

        // reset fee
        daoFeeRegistry.resetTokenFee(address(folio));
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0);
    }

    function test_cannotResetTokenFeeIfNotOwner() public {
        vm.prank(user2);
        vm.expectRevert(IFolioFeeRegistry.FolioFeeRegistry__InvalidCaller.selector);
        daoFeeRegistry.resetTokenFee(address(folio));
    }
}
