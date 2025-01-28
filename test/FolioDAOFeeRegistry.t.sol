// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { IFolioDeployer } from "contracts/interfaces/IFolioDeployer.sol";
import { IFolioDAOFeeRegistry } from "contracts/interfaces/IFolioDAOFeeRegistry.sol";
import { FolioDAOFeeRegistry, MAX_DAO_FEE } from "contracts/folio/FolioDAOFeeRegistry.sol";
import { MAX_AUCTION_LENGTH, MAX_TVL_FEE, MAX_AUCTION_DELAY } from "contracts/Folio.sol";
import "./base/BaseTest.sol";

contract FolioDAOFeeRegistryTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;

    function _testSetup() public virtual override {
        super._testSetup();
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
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        // 50% folio fee annually -- different from dao fee
        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);

        (folio, proxyAdmin) = createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_AUCTION_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_TVL_FEE, // 50% annually
            0,
            owner,
            dao,
            auctionLauncher
        );
        vm.stopPrank();
    }

    function test_constructor() public {
        FolioDAOFeeRegistry folioDAOFeeRegistry = new FolioDAOFeeRegistry(IRoleRegistry(address(roleRegistry)), dao);
        assertEq(address(folioDAOFeeRegistry.roleRegistry()), address(roleRegistry));
        (address recipient, uint256 feeNumerator, uint256 feeDenominator) = folioDAOFeeRegistry.getFeeDetails(
            address(folio)
        );
        assertEq(recipient, dao);
        assertEq(feeNumerator, 0); // no fee numerator set yet
        assertEq(feeDenominator, folioDAOFeeRegistry.FEE_DENOMINATOR());
    }

    function test_cannotCreateFeeRegistryWithInvalidRoleRegistry() public {
        vm.expectRevert(IFolioDAOFeeRegistry.FolioDAOFeeRegistry__InvalidRoleRegistry.selector);
        new FolioDAOFeeRegistry(IRoleRegistry(address(0)), dao);
    }

    function test_cannotCreateFeeRegistryWithInvalidFeeRecipient() public {
        vm.expectRevert(IFolioDAOFeeRegistry.FolioDAOFeeRegistry__InvalidFeeRecipient.selector);
        new FolioDAOFeeRegistry(IRoleRegistry(address(roleRegistry)), address(0));
    }

    function test_setFeeRecipient() public {
        address recipient;
        (recipient, , ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(recipient, dao);

        vm.expectEmit(true, true, false, true);
        emit IFolioDAOFeeRegistry.FeeRecipientSet(user2);
        daoFeeRegistry.setFeeRecipient(user2);

        (recipient, , ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(recipient, user2);
    }

    function test_cannotSetFeeRecipientIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert(IFolioDAOFeeRegistry.FolioDAOFeeRegistry__InvalidCaller.selector);
        daoFeeRegistry.setFeeRecipient(user2);
    }

    function test_cannotSetFeeRecipientWithInvalidAddress() public {
        vm.expectRevert(IFolioDAOFeeRegistry.FolioDAOFeeRegistry__InvalidFeeRecipient.selector);
        daoFeeRegistry.setFeeRecipient(address(0));
    }

    function test_cannotSetFeeRecipientIfAlreadySet() public {
        vm.expectRevert(IFolioDAOFeeRegistry.FolioDAOFeeRegistry__FeeRecipientAlreadySet.selector);
        daoFeeRegistry.setFeeRecipient(dao);
    }

    function test_setDefaultFeeNumerator() public {
        uint256 numerator;
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0);

        vm.expectEmit(true, true, false, true);
        emit IFolioDAOFeeRegistry.DefaultFeeNumeratorSet(0.1e18);

        daoFeeRegistry.setDefaultFeeNumerator(0.1e18);

        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0.1e18);
    }

    function test_cannotSetDefaultTokenFeeNumeratorIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert(IFolioDAOFeeRegistry.FolioDAOFeeRegistry__InvalidCaller.selector);
        daoFeeRegistry.setDefaultFeeNumerator(0.1e18);
    }

    function test_cannotSetDefaultFeeNumeratorWithInvalidValue() public {
        vm.expectRevert(IFolioDAOFeeRegistry.FolioDAOFeeRegistry__InvalidFeeNumerator.selector);
        daoFeeRegistry.setDefaultFeeNumerator(MAX_DAO_FEE + 1);
    }

    function test_setTokenFeeNumerator() public {
        uint256 numerator;
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0);

        vm.expectEmit(true, true, false, true);
        emit IFolioDAOFeeRegistry.TokenFeeNumeratorSet(address(folio), 0.1e18, true);
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 0.1e18);

        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0.1e18);
    }

    function test_cannotSetTokenFeeNumeratorIfNotOwner() public {
        vm.prank(user2);
        vm.expectRevert(IFolioDAOFeeRegistry.FolioDAOFeeRegistry__InvalidCaller.selector);
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 0.1e18);
    }

    function test_cannotSetTokenFeeNumeratorWithInvalidValue() public {
        vm.expectRevert(IFolioDAOFeeRegistry.FolioDAOFeeRegistry__InvalidFeeNumerator.selector);
        daoFeeRegistry.setTokenFeeNumerator(address(folio), MAX_DAO_FEE + 1);
    }

    function test_usesDefaultFeeNumeratorOnlyWhenTokenNumeratorIsNotSet() public {
        uint256 numerator;
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0); // default

        // set new value for default fee numerator
        daoFeeRegistry.setDefaultFeeNumerator(0.05e18);

        // still using default
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0.05e18);

        // set token fee numerator
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 0.1e18);

        // Token fee numerator overrides default
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0.1e18);
    }

    function test_resetTokenFee() public {
        uint256 numerator;

        // set token fee numerator
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 0.1e18);
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0.1e18);

        // reset fee
        vm.expectEmit(true, true, false, true);
        emit IFolioDAOFeeRegistry.TokenFeeNumeratorSet(address(folio), 0, false);
        daoFeeRegistry.resetTokenFee(address(folio));
        (, numerator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        assertEq(numerator, 0);
    }

    function test_cannotResetTokenFeeIfNotOwner() public {
        vm.prank(user2);
        vm.expectRevert(IFolioDAOFeeRegistry.FolioDAOFeeRegistry__InvalidCaller.selector);
        daoFeeRegistry.resetTokenFee(address(folio));
    }
}
