// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio, MAX_AUCTION_LENGTH, MIN_AUCTION_LENGTH, MAX_FOLIO_FEE, MAX_TRADE_DELAY, MAX_TTL, MAX_FEE_RECIPIENTS, MAX_MINTING_FEE, MIN_DAO_MINTING_FEE, MAX_PRICE_RANGE, MAX_RATE } from "contracts/Folio.sol";
import { MAX_DAO_FEE } from "contracts/folio/FolioDAOFeeRegistry.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FolioProxyAdmin, FolioProxy } from "contracts/folio/FolioProxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { FolioDeployerV2 } from "test/utils/upgrades/FolioDeployerV2.sol";
import { MockReentrantERC20 } from "test/utils/MockReentrantERC20.sol";
import "./base/BaseTest.sol";

contract FolioTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;
    uint256 internal constant MAX_FOLIO_FEE_PER_SECOND = 21979552667; // D18{1/s} 50% annually, per second

    IFolio.Range internal FULL_SELL = IFolio.Range(0, 0, MAX_RATE);
    IFolio.Range internal FULL_BUY = IFolio.Range(MAX_RATE, 1, MAX_RATE);

    IFolio.Prices internal ZERO_PRICES = IFolio.Prices(0, 0);

    function _testSetup() public virtual override {
        super._testSetup();
        _deployTestFolio();
    }

    function _deployTestFolio() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        tokens[2] = address(MEME);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        amounts[2] = D27_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        // 50% folio fee annually
        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);
        MEME.approve(address(folioDeployer), type(uint256).max);

        (folio, proxyAdmin) = createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_FOLIO_FEE,
            0,
            owner,
            dao,
            tradeLauncher
        );
        vm.stopPrank();
    }

    function test_deployment() public view {
        assertEq(folio.name(), "Test Folio", "wrong name");
        assertEq(folio.symbol(), "TFOLIO", "wrong symbol");
        assertEq(folio.mandate(), "mandate", "wrong mandate");
        assertEq(folio.decimals(), 18, "wrong decimals");
        assertEq(folio.totalSupply(), INITIAL_SUPPLY, "wrong total supply");
        assertEq(folio.balanceOf(owner), INITIAL_SUPPLY, "wrong owner balance");
        assertTrue(folio.hasRole(DEFAULT_ADMIN_ROLE, owner), "wrong governor");
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 3, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(_assets[2], address(MEME), "wrong third asset");
        assertEq(USDC.balanceOf(address(folio)), D6_TOKEN_10K, "wrong folio usdc balance");
        assertEq(DAI.balanceOf(address(folio)), D18_TOKEN_10K, "wrong folio dai balance");
        assertEq(MEME.balanceOf(address(folio)), D27_TOKEN_10K, "wrong folio meme balance");
        assertEq(folio.folioFee(), MAX_FOLIO_FEE_PER_SECOND, "wrong folio fee");
        (address r1, uint256 bps1) = folio.feeRecipients(0);
        assertEq(r1, owner, "wrong first recipient");
        assertEq(bps1, 0.9e18, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.feeRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 0.1e18, "wrong second recipient bps");
        assertEq(folio.version(), "1.0.0");
    }

    function test_cannotInitializeWithInvalidAsset() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(0);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        // Create uninitialized Folio
        FolioProxyAdmin folioAdmin = new FolioProxyAdmin(owner, address(versionRegistry));
        address folioImplementation = versionRegistry.getImplementationForVersion(keccak256("1.0.0"));
        Folio newFolio = Folio(address(new FolioProxy(folioImplementation, address(folioAdmin))));

        vm.startPrank(owner);
        USDC.transfer(address(newFolio), amounts[0]);
        vm.stopPrank();

        IFolio.FolioBasicDetails memory basicDetails = IFolio.FolioBasicDetails({
            name: "Test Folio",
            symbol: "TFOLIO",
            assets: tokens,
            amounts: amounts,
            initialShares: INITIAL_SUPPLY
        });

        IFolio.FolioAdditionalDetails memory additionalDetails = IFolio.FolioAdditionalDetails({
            tradeDelay: MAX_TRADE_DELAY,
            auctionLength: MAX_AUCTION_LENGTH,
            feeRecipients: recipients,
            folioFee: MAX_FOLIO_FEE,
            mintingFee: 0,
            mandate: "mandate"
        });

        // Attempt to initialize
        vm.expectRevert(IFolio.Folio__InvalidAsset.selector);
        newFolio.initialize(basicDetails, additionalDetails, address(this), address(daoFeeRegistry));
    }

    function test_cannotCreateWithZeroInitialShares() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);

        Folio newFolio;
        FolioProxyAdmin folioAdmin;

        vm.expectRevert(IFolio.Folio__ZeroInitialShares.selector);
        (newFolio, folioAdmin) = createFolio(
            tokens,
            amounts,
            0, // zero initial shares
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_FOLIO_FEE,
            0,
            owner,
            dao,
            tradeLauncher
        );
        vm.stopPrank();
    }

    function test_getFolio() public view {
        (address[] memory _assets, uint256[] memory _amounts) = folio.folio();
        assertEq(_assets.length, 3, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(_assets[2], address(MEME), "wrong third asset");

        assertEq(_amounts.length, 3, "wrong amounts length");
        assertEq(_amounts[0], D6_TOKEN_1, "wrong first amount");
        assertEq(_amounts[1], D18_TOKEN_1, "wrong second amount");
        assertEq(_amounts[2], D27_TOKEN_1, "wrong third amount");
    }

    function test_toAssets() public view {
        (address[] memory _assets, uint256[] memory _amounts) = folio.toAssets(0.5e18, Math.Rounding.Floor);
        assertEq(_assets.length, 3, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(_assets[2], address(MEME), "wrong third asset");

        assertEq(_amounts.length, 3, "wrong amounts length");
        assertEq(_amounts[0], D6_TOKEN_1 / 2, "wrong first amount");
        assertEq(_amounts[1], D18_TOKEN_1 / 2, "wrong second amount");
        assertEq(_amounts[2], D27_TOKEN_1 / 2, "wrong third amount");
    }

    function test_toAssets_noReentrancy() public {
        // deploy and mint reentrant token
        MockReentrantERC20 REENTRANT = new MockReentrantERC20("REENTRANT", "REENTER", 18);
        address[] memory actors = new address[](1);
        actors[0] = owner;
        uint256[] memory amounts_18 = new uint256[](1);
        amounts_18[0] = D18_TOKEN_1M;
        mintToken(address(REENTRANT), actors, amounts_18);

        // create folio
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(REENTRANT);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        // 50% folio fee annually
        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        REENTRANT.approve(address(folioDeployer), type(uint256).max);

        (folio, proxyAdmin) = createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_TRADE_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_FOLIO_FEE,
            0,
            owner,
            dao,
            tradeLauncher
        );
        vm.stopPrank();

        // Set reentrancy on and attempt to mint
        REENTRANT.setReentrancy(true);

        vm.startPrank(owner);
        USDC.approve(address(folio), type(uint256).max);
        REENTRANT.approve(address(folio), type(uint256).max);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        folio.mint(1e18, owner);
        vm.stopPrank();
    }

    function test_mint() public {
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        uint256 startingUSDCBalance = USDC.balanceOf(address(folio));
        uint256 startingDAIBalance = DAI.balanceOf(address(folio));
        uint256 startingMEMEBalance = MEME.balanceOf(address(folio));
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);
        folio.mint(1e22, user1);
        assertEq(folio.balanceOf(user1), 1e22 - 1e22 / 2000, "wrong user1 balance");
        assertApproxEqAbs(
            USDC.balanceOf(address(folio)),
            startingUSDCBalance + D6_TOKEN_10K,
            1,
            "wrong folio usdc balance"
        );
        assertApproxEqAbs(
            DAI.balanceOf(address(folio)),
            startingDAIBalance + D18_TOKEN_10K,
            1,
            "wrong folio dai balance"
        );
        assertApproxEqAbs(
            MEME.balanceOf(address(folio)),
            startingMEMEBalance + D27_TOKEN_10K,
            1e9,
            "wrong folio meme balance"
        );
    }

    function test_mintWithFeeNoDAOCut() public {
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        uint256 startingUSDCBalance = USDC.balanceOf(address(folio));
        uint256 startingDAIBalance = DAI.balanceOf(address(folio));
        uint256 startingMEMEBalance = MEME.balanceOf(address(folio));

        // set mintingFee to 10%
        vm.prank(owner);
        folio.setMintingFee(MAX_MINTING_FEE);
        // DAO cut is still 0% at this point

        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);

        uint256 amt = 1e22;
        folio.mint(amt, user1);
        assertEq(folio.balanceOf(user1), amt - amt / 10, "wrong user1 balance");
        assertApproxEqAbs(
            USDC.balanceOf(address(folio)),
            startingUSDCBalance + D6_TOKEN_10K,
            1,
            "wrong folio usdc balance"
        );
        assertApproxEqAbs(
            DAI.balanceOf(address(folio)),
            startingDAIBalance + D18_TOKEN_10K,
            1,
            "wrong folio dai balance"
        );
        assertApproxEqAbs(
            MEME.balanceOf(address(folio)),
            startingMEMEBalance + D27_TOKEN_10K,
            1e9,
            "wrong folio meme balance"
        );

        // minting fee should be manifested in total supply and both streams of fee shares
        assertEq(folio.totalSupply(), amt * 2, "total supply off"); // genesis supply + new mint + 10% increase
        uint256 daoPendingFeeShares = (amt * MIN_DAO_MINTING_FEE) / 1e18;
        assertEq(folio.daoPendingFeeShares(), daoPendingFeeShares, "wrong dao pending fee shares"); // only 5 bps
        assertEq(
            folio.feeRecipientsPendingFeeShares(),
            amt / 10 - daoPendingFeeShares,
            "wrong fee recipients pending fee shares"
        );
    }

    function test_mintWithFeeDAOCut() public {
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        uint256 startingUSDCBalance = USDC.balanceOf(address(folio));
        uint256 startingDAIBalance = DAI.balanceOf(address(folio));
        uint256 startingMEMEBalance = MEME.balanceOf(address(folio));

        // set mintingFee to 10%
        vm.prank(owner);
        folio.setMintingFee(MAX_MINTING_FEE);
        daoFeeRegistry.setDefaultFeeNumerator(MAX_DAO_FEE); // DAO fee 50%

        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);

        uint256 amt = 1e22;
        folio.mint(amt, user1);
        assertEq(folio.balanceOf(user1), amt - amt / 10, "wrong user1 balance");
        assertApproxEqAbs(
            USDC.balanceOf(address(folio)),
            startingUSDCBalance + D6_TOKEN_10K,
            1,
            "wrong folio usdc balance"
        );
        assertApproxEqAbs(
            DAI.balanceOf(address(folio)),
            startingDAIBalance + D18_TOKEN_10K,
            1,
            "wrong folio dai balance"
        );
        assertApproxEqAbs(
            MEME.balanceOf(address(folio)),
            startingMEMEBalance + D27_TOKEN_10K,
            1e9,
            "wrong folio meme balance"
        );

        // minting fee should be manifested in total supply and both streams of fee shares
        assertEq(folio.totalSupply(), amt * 2, "total supply off"); // genesis supply + new mint + 10% increase
        uint256 daoPendingFeeShares = (amt / 10) / 2;
        assertEq(folio.daoPendingFeeShares(), daoPendingFeeShares, "wrong dao pending fee shares"); // only 5 bps
        assertEq(
            folio.feeRecipientsPendingFeeShares(),
            amt / 10 - daoPendingFeeShares,
            "wrong fee recipients pending fee shares"
        );
    }

    function test_mintWithFeeDAOCutFloor() public {
        // in this testcase the fee recipients receive 0 even though a folioFee is nonzero
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        uint256 startingUSDCBalance = USDC.balanceOf(address(folio));
        uint256 startingDAIBalance = DAI.balanceOf(address(folio));
        uint256 startingMEMEBalance = MEME.balanceOf(address(folio));

        // set mintingFee to MIN_DAO_MINTING_FEE, 5 bps
        vm.prank(owner);
        folio.setMintingFee(MIN_DAO_MINTING_FEE);
        // leave daoFeeRegistry fee at 0 (default)

        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);

        uint256 amt = 1e22;
        folio.mint(amt, user1);
        assertEq(folio.balanceOf(user1), amt - (amt * MIN_DAO_MINTING_FEE) / 1e18, "wrong user1 balance");
        assertApproxEqAbs(
            USDC.balanceOf(address(folio)),
            startingUSDCBalance + D6_TOKEN_10K,
            1,
            "wrong folio usdc balance"
        );
        assertApproxEqAbs(
            DAI.balanceOf(address(folio)),
            startingDAIBalance + D18_TOKEN_10K,
            1,
            "wrong folio dai balance"
        );
        assertApproxEqAbs(
            MEME.balanceOf(address(folio)),
            startingMEMEBalance + D27_TOKEN_10K,
            1e9,
            "wrong folio meme balance"
        );

        // minting fee should be manifested in total supply and ONLY the DAO's side of the stream
        assertEq(folio.totalSupply(), amt * 2, "total supply off");
        assertEq(folio.daoPendingFeeShares(), (amt * MIN_DAO_MINTING_FEE) / 1e18, "wrong dao pending fee shares");
        assertEq(folio.feeRecipientsPendingFeeShares(), 0, "wrong fee recipients pending fee shares");
    }

    function test_cannotMintIfFolioKilled() public {
        vm.prank(owner);
        folio.killFolio();

        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IFolio.Folio__FolioKilled.selector));
        folio.mint(1e22, user1);
        vm.stopPrank();
        assertEq(folio.balanceOf(user1), 0, "wrong ending user1 balance");
    }

    function test_redeem() public {
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);
        folio.mint(1e22, user1);
        assertEq(folio.balanceOf(user1), 1e22 - 1e22 / 2000, "wrong user1 balance");
        uint256 startingUSDCBalanceFolio = USDC.balanceOf(address(folio));
        uint256 startingDAIBalanceFolio = DAI.balanceOf(address(folio));
        uint256 startingMEMEBalanceFolio = MEME.balanceOf(address(folio));
        uint256 startingUSDCBalanceAlice = USDC.balanceOf(address(user1));
        uint256 startingDAIBalanceAlice = DAI.balanceOf(address(user1));
        uint256 startingMEMEBalanceAlice = MEME.balanceOf(address(user1));

        address[] memory basket = new address[](3);
        basket[0] = address(USDC);
        basket[1] = address(DAI);
        basket[2] = address(MEME);
        uint256[] memory minAmountsOut = new uint256[](3);

        folio.redeem(5e21, user1, basket, minAmountsOut);
        assertApproxEqAbs(
            USDC.balanceOf(address(folio)),
            startingUSDCBalanceFolio - D6_TOKEN_10K / 2,
            1,
            "wrong folio usdc balance"
        );
        assertApproxEqAbs(
            DAI.balanceOf(address(folio)),
            startingDAIBalanceFolio - D18_TOKEN_10K / 2,
            1,
            "wrong folio dai balance"
        );
        assertApproxEqAbs(
            MEME.balanceOf(address(folio)),
            startingMEMEBalanceFolio - D27_TOKEN_10K / 2,
            1e9,
            "wrong folio meme balance"
        );
        assertApproxEqAbs(
            USDC.balanceOf(user1),
            startingUSDCBalanceAlice + D6_TOKEN_10K / 2,
            1,
            "wrong alice usdc balance"
        );
        assertApproxEqAbs(
            DAI.balanceOf(user1),
            startingDAIBalanceAlice + D18_TOKEN_10K / 2,
            1,
            "wrong alice dai balance"
        );
        assertApproxEqAbs(
            MEME.balanceOf(user1),
            startingMEMEBalanceAlice + D27_TOKEN_10K / 2,
            1e9,
            "wrong alice meme balance"
        );
    }

    function test_addToBasket() public {
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 3, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(_assets[2], address(MEME), "wrong third asset");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit IFolio.BasketTokenAdded(address(USDT));
        folio.addToBasket(USDT);

        (_assets, ) = folio.totalAssets();
        assertEq(_assets.length, 4, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(_assets[2], address(MEME), "wrong third asset");
        assertEq(_assets[3], address(USDT), "wrong fourth asset");
        vm.stopPrank();
    }

    function test_cannotAddToBasketIfNotOwner() public {
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 3, "wrong assets length");

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.addToBasket(USDT);
        vm.stopPrank();
    }

    function test_cannotAddToBasketIfDuplicate() public {
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 3, "wrong assets length");

        vm.startPrank(owner);
        vm.expectRevert(IFolio.Folio__BasketModificationFailed.selector);
        folio.addToBasket(USDC); // cannot add duplicate
        vm.stopPrank();
    }

    function test_removeFromBasket() public {
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 3, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(_assets[2], address(MEME), "wrong third asset");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit IFolio.BasketTokenRemoved(address(MEME));
        folio.removeFromBasket(MEME);

        (_assets, ) = folio.totalAssets();
        assertEq(_assets.length, 2, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        vm.stopPrank();
    }

    function test_cannotRemoveFromBasketIfNotOwner() public {
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 3, "wrong assets length");

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.removeFromBasket(MEME);
        vm.stopPrank();
    }

    function test_cannotRemoveFromBasketIfNotAvailable() public {
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 3, "wrong assets length");

        vm.startPrank(owner);
        vm.expectRevert(IFolio.Folio__BasketModificationFailed.selector);
        folio.removeFromBasket(USDT); // cannot remove, not in basket
        vm.stopPrank();
    }

    function test_daoFee() public {
        // set dao fee to 0.15%
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 0.15e18);

        uint256 supplyBefore = folio.totalSupply();

        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        // validate pending fees have been accumulated -- 50% fee = 100% of supply
        assertApproxEqAbs(supplyBefore, pendingFeeShares, 1e12, "wrong pending fee shares");

        uint256 initialOwnerShares = folio.balanceOf(owner);
        folio.distributeFees();

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = (pendingFeeShares * daoFeeNumerator + daoFeeDenominator - 1) /
            daoFeeDenominator +
            1;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares");

        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(folio.balanceOf(owner), initialOwnerShares + (remainingShares * 0.9e18) / 1e18, "wrong owner shares");
        assertEq(folio.balanceOf(feeReceiver), (remainingShares * 0.1e18) / 1e18, "wrong fee receiver shares");
    }

    function test_setFeeRecipients() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](3);
        recipients[0] = IFolio.FeeRecipient(owner, 0.8e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.05e18);
        recipients[2] = IFolio.FeeRecipient(user1, 0.15e18);
        vm.expectEmit(true, true, false, true);
        emit IFolio.FeeRecipientSet(owner, 0.8e18);
        emit IFolio.FeeRecipientSet(feeReceiver, 0.05e18);
        emit IFolio.FeeRecipientSet(user1, 0.15e18);
        folio.setFeeRecipients(recipients);

        (address r1, uint256 bps1) = folio.feeRecipients(0);
        assertEq(r1, owner, "wrong first recipient");
        assertEq(bps1, 0.8e18, "wrong first recipient bps");
        (address r2, uint256 bps2) = folio.feeRecipients(1);
        assertEq(r2, feeReceiver, "wrong second recipient");
        assertEq(bps2, 0.05e18, "wrong second recipient bps");
        (address r3, uint256 bps3) = folio.feeRecipients(2);
        assertEq(r3, user1, "wrong third recipient");
        assertEq(bps3, 0.15e18, "wrong third recipient bps");
    }

    function test_cannotSetFeeRecipientsIfNotOwner() public {
        vm.startPrank(user1);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](3);
        recipients[0] = IFolio.FeeRecipient(owner, 0.8e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.05e18);
        recipients[2] = IFolio.FeeRecipient(user1, 0.15e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.setFeeRecipients(recipients);
    }

    function test_setFeeRecipients_DistributesFees() public {
        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        uint256 initialOwnerShares = folio.balanceOf(owner);
        uint256 initialDaoShares = folio.balanceOf(dao);

        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](3);
        recipients[0] = IFolio.FeeRecipient(owner, 0.8e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.05e18);
        recipients[2] = IFolio.FeeRecipient(user1, 0.15e18);
        vm.expectEmit(true, true, false, true);
        emit IFolio.FeeRecipientSet(owner, 0.8e18);
        emit IFolio.FeeRecipientSet(feeReceiver, 0.05e18);
        emit IFolio.FeeRecipientSet(user1, 0.15e18);
        folio.setFeeRecipients(recipients);

        assertEq(folio.daoPendingFeeShares(), 0, "wrong dao pending fee shares");
        assertEq(folio.feeRecipientsPendingFeeShares(), 0, "wrong fee recipients pending fee shares");

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator + 1;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares");

        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(
            folio.balanceOf(owner),
            initialOwnerShares + (remainingShares * 0.9e18) / 1e18 + 1,
            "wrong owner shares"
        );
        assertEq(folio.balanceOf(feeReceiver), (remainingShares * 0.1e18) / 1e18, "wrong fee receiver shares");
    }

    function test_setFolioFee() public {
        vm.startPrank(owner);
        assertEq(folio.folioFee(), MAX_FOLIO_FEE_PER_SECOND, "wrong folio fee");
        uint256 newFolioFee = MAX_FOLIO_FEE / 1000;
        uint256 newFolioFeePerSecond = 15858860;
        vm.expectEmit(true, true, false, true);
        emit IFolio.FolioFeeSet(newFolioFeePerSecond, MAX_FOLIO_FEE / 1000);
        folio.setFolioFee(newFolioFee);
        assertEq(folio.folioFee(), newFolioFeePerSecond, "wrong folio fee");
    }

    function test_setFolioFeeOutOfBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(IFolio.Folio__FolioFeeTooLow.selector);
        folio.setFolioFee(1);

        vm.expectRevert(IFolio.Folio__FolioFeeTooHigh.selector);
        folio.setFolioFee(MAX_FOLIO_FEE + 1);
    }

    function test_setTradeDelay() public {
        vm.startPrank(owner);
        assertEq(folio.tradeDelay(), MAX_TRADE_DELAY, "wrong trade delay");
        uint256 newTradeDelay = 0;
        vm.expectEmit(true, true, false, true);
        emit IFolio.TradeDelaySet(newTradeDelay);
        folio.setTradeDelay(newTradeDelay);
        assertEq(folio.tradeDelay(), newTradeDelay, "wrong trade delay");
    }

    function test_setAuctionLength() public {
        vm.startPrank(owner);
        assertEq(folio.auctionLength(), MAX_AUCTION_LENGTH, "wrong auction length");
        uint256 newAuctionLength = MIN_AUCTION_LENGTH;
        vm.expectEmit(true, true, false, true);
        emit IFolio.AuctionLengthSet(newAuctionLength);
        folio.setAuctionLength(newAuctionLength);
        assertEq(folio.auctionLength(), newAuctionLength, "wrong auction length");
    }

    function test_setMandate() public {
        vm.startPrank(owner);
        assertEq(folio.mandate(), "mandate", "wrong mandate");
        string memory newMandate = "new mandate";
        vm.expectEmit(true, true, false, true);
        emit IFolio.MandateSet(newMandate);
        folio.setMandate(newMandate);
        assertEq(folio.mandate(), newMandate);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                dao,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(dao);
        folio.setMandate(newMandate);
    }

    function test_setMintingFee() public {
        vm.startPrank(owner);
        assertEq(folio.mintingFee(), 0, "wrong minting fee");
        uint256 newMintingFee = MAX_MINTING_FEE;
        vm.expectEmit(true, true, false, true);
        emit IFolio.MintingFeeSet(newMintingFee);
        folio.setMintingFee(newMintingFee);
        assertEq(folio.mintingFee(), newMintingFee, "wrong minting fee");
    }

    function test_cannotSetMintingFeeIfNotOwner() public {
        vm.startPrank(user1);
        uint256 newMintingFee = MAX_MINTING_FEE;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.setMintingFee(newMintingFee);
    }

    function test_setMintingFee_InvalidFee() public {
        vm.startPrank(owner);
        uint256 newMintingFee = MAX_MINTING_FEE + 1;
        vm.expectRevert(IFolio.Folio__MintingFeeTooHigh.selector);
        folio.setMintingFee(newMintingFee);
    }

    function test_cannotSetFolioFeeIfNotOwner() public {
        vm.startPrank(user1);
        uint256 newFolioFee = MAX_FOLIO_FEE / 1000;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.setFolioFee(newFolioFee);
    }

    function test_setFolioFee_DistributesFees() public {
        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        uint256 initialOwnerShares = folio.balanceOf(owner);
        uint256 initialDaoShares = folio.balanceOf(dao);

        vm.startPrank(owner);
        uint256 newFolioFee = MAX_FOLIO_FEE / 1000;
        folio.setFolioFee(newFolioFee);

        assertEq(folio.daoPendingFeeShares(), 0, "wrong dao pending fee shares");
        assertEq(folio.feeRecipientsPendingFeeShares(), 0, "wrong fee recipients pending fee shares");

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator + 1;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares");

        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(
            folio.balanceOf(owner),
            initialOwnerShares + (remainingShares * 0.9e18) / 1e18 + 1,
            "wrong owner shares"
        );
        assertEq(folio.balanceOf(feeReceiver), (remainingShares * 0.1e18) / 1e18, "wrong fee receiver shares");
    }

    function test_setFolioFeeRecipients_InvalidRecipient() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(address(0), 0.1e18);
        vm.expectRevert(IFolio.Folio__FeeRecipientInvalidAddress.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFolioFeeRecipients_InvalidBps() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](1);
        //    recipients[0] = IFolio.FeeRecipient(owner, 0.1e18);
        recipients[0] = IFolio.FeeRecipient(feeReceiver, 0);
        vm.expectRevert(IFolio.Folio__FeeRecipientInvalidFeeShare.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFolioFeeRecipients_InvalidTotal() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.0999e18);
        vm.expectRevert(IFolio.Folio__BadFeeTotal.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFolioFeeRecipients_EmptyList() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](0);
        vm.expectRevert(IFolio.Folio__BadFeeTotal.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFolioFeeRecipients_TooManyRecipients() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](MAX_FEE_RECIPIENTS + 1);
        // for loop from 0 to MAX_FEE_RECIPIENTS, setup recipient[i] with 1e27 / 64 for each
        for (uint256 i; i < MAX_FEE_RECIPIENTS + 1; i++) {
            recipients[i] = IFolio.FeeRecipient(feeReceiver, uint96(1e27) / uint96(MAX_FEE_RECIPIENTS + 1));
        }

        vm.expectRevert(IFolio.Folio__TooManyFeeRecipients.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFolioDAOFeeRegistry() public {
        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        uint256 initialOwnerShares = folio.balanceOf(owner);
        uint256 initialDaoShares = folio.balanceOf(dao);
        uint256 initialFeeReceiverShares = folio.balanceOf(feeReceiver);

        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));

        daoFeeRegistry.setTokenFeeNumerator(address(folio), 0.1e18);

        // check receipient balances
        uint256 expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator + 1;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares, 1st change");
        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(
            folio.balanceOf(owner),
            initialOwnerShares + (remainingShares * 0.9e18) / 1e18 + 1,
            "wrong owner shares, 1st change"
        );
        assertEq(
            folio.balanceOf(feeReceiver),
            initialFeeReceiverShares + (remainingShares * 0.1e18) / 1e18,
            "wrong fee receiver shares, 1st change"
        );

        // fast forward again, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);

        pendingFeeShares = folio.getPendingFeeShares();

        initialOwnerShares = folio.balanceOf(owner);
        initialDaoShares = folio.balanceOf(dao);
        initialFeeReceiverShares = folio.balanceOf(feeReceiver);
        (, daoFeeNumerator, daoFeeDenominator) = daoFeeRegistry.getFeeDetails(address(folio));

        // set new fee numerator, should distribute fees
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 0.05e18);

        // check receipient balances
        expectedDaoShares =
            initialDaoShares +
            (pendingFeeShares * daoFeeNumerator + daoFeeDenominator - 1) /
            daoFeeDenominator +
            1;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares, 2nd change");
        remainingShares = pendingFeeShares - expectedDaoShares;
        assertApproxEqAbs(
            folio.balanceOf(owner),
            initialOwnerShares + (remainingShares * 0.9e18) / 1e18,
            3,
            "wrong owner shares, 2nd change"
        );
        assertEq(
            folio.balanceOf(feeReceiver),
            initialFeeReceiverShares + (remainingShares * 0.1e18) / 1e18,
            "wrong fee receiver shares, 2nd change"
        );
    }

    function test_atomicBidWithoutCallback() public {
        // bid in two chunks, one at start time and one at end time

        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });

        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, MAX_RATE, 1e27, 1e27);

        // bid once at start time

        vm.startPrank(user1);
        USDT.approve(address(folio), amt);
        vm.expectEmit(true, false, false, true);
        emit IFolio.TradeBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, false, bytes(""));

        (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);
        assertEq(folio.getBid(0, start, amt), amt, "wrong start bid amount"); // 1x
        assertEq(folio.getBid(0, (start + end) / 2, amt), amt, "wrong mid bid amount"); // 1x
        assertEq(folio.getBid(0, end, amt), amt, "wrong end bid amount"); // 1x

        // bid a 2nd time for the rest of the volume, at end time
        vm.warp(end);
        USDT.approve(address(folio), amt);
        vm.expectEmit(true, false, false, true);
        emit IFolio.TradeBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();

        assertEq(folio.lot(0, block.timestamp), 0, "auction should be empty");
    }

    function test_atomicBidWithCallback() public {
        uint256 amt = D6_TOKEN_10K;
        // bid in two chunks, one at start time and one at end time
        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, MAX_RATE, 1e27, 1e27);

        // bid once at start time

        MockBidder mockBidder = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder), amt / 2);
        vm.prank(address(mockBidder));
        vm.expectEmit(true, false, false, true);
        emit IFolio.TradeBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);
        assertEq(folio.getBid(0, start, amt), amt, "wrong start bid amount"); // 1x
        assertEq(folio.getBid(0, (start + end) / 2, amt), amt, "wrong mid bid amount"); // 1x
        assertEq(folio.getBid(0, end, amt), amt, "wrong end bid amount"); // 1x

        // bid a 2nd time for the rest of the volume, at end time

        vm.warp(end);
        MockBidder mockBidder2 = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder2), amt / 2);
        vm.prank(address(mockBidder2));
        vm.expectEmit(true, false, false, true);
        emit IFolio.TradeBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder2)), 0, "wrong mock bidder2 balance");
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();

        assertEq(folio.lot(0, block.timestamp), 0, "auction should be empty");
    }

    function test_auctionBidWithoutCallback() public {
        // bid in two chunks, one at start time and one at end time

        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        // bid once at start time

        vm.startPrank(user1);
        USDT.approve(address(folio), amt * 5);
        vm.expectEmit(true, false, false, true);
        emit IFolio.TradeBid(0, amt / 2, amt * 5);
        folio.bid(0, amt / 2, amt * 5, false, bytes(""));

        (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);
        assertEq(folio.getBid(0, start, amt), amt * 10, "wrong start bid amount"); // 10x
        assertEq(folio.getBid(0, (start + end) / 2, amt), 31622776602, "wrong mid bid amount"); // ~3.16x
        assertEq(folio.getBid(0, end, amt), amt, "wrong end bid amount"); // 1x
        vm.warp(end);

        // bid a 2nd time for the rest of the volume, at end time
        USDT.approve(address(folio), amt);
        vm.expectEmit(true, false, false, true);
        emit IFolio.TradeBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionBidWithCallback() public {
        // bid in two chunks, one at start time and one at end time
        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });

        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        // bid once at start time

        MockBidder mockBidder = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder), amt * 5);
        vm.prank(address(mockBidder));
        vm.expectEmit(true, false, false, true);
        emit IFolio.TradeBid(0, amt / 2, amt * 5);
        folio.bid(0, amt / 2, amt * 5, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        // check prices

        (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);
        assertEq(folio.getBid(0, start, amt), amt * 10, "wrong start bid amount"); // 10x
        assertEq(folio.getBid(0, (start + end) / 2, amt), 31622776602, "wrong mid bid amount"); // ~3.16x
        assertEq(folio.getBid(0, end, amt), amt, "wrong end bid amount"); // 1x

        // bid a 2nd time for the rest of the volume, at end time

        vm.warp(end);
        MockBidder mockBidder2 = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder2), amt / 2);
        vm.prank(address(mockBidder2));
        vm.expectEmit(true, false, false, true);
        emit IFolio.TradeBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder2)), 0, "wrong mock bidder2 balance");
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionTinyPrices() public {
        // 1e-19 price

        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D27_TOKEN_1;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(MEME), address(USDT), tradeStruct);
        folio.approveTrade(MEME, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, MAX_RATE, 1e5, 1);

        // should have right bid at start, middle, and end of auction

        (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);
        assertEq(folio.getBid(0, start, amt), amt / 1e22, "wrong start bid amount");
        assertEq(folio.getBid(0, (start + end) / 2, amt), 316, "wrong mid bid amount");
        assertEq(folio.getBid(0, end, amt), 1, "wrong end bid amount");
    }

    function test_auctionKillTradeByTradeProposer() public {
        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        // killTrade should not be callable by just anyone
        vm.expectRevert(IFolio.Folio__Unauthorized.selector);
        folio.killTrade(0);

        (, , , , , , , , , uint256 end, ) = folio.trades(0);
        vm.startPrank(dao);
        vm.expectEmit(true, false, false, true);
        emit IFolio.TradeKilled(0);
        folio.killTrade(0);

        // next auction index should revert

        vm.expectRevert();
        folio.killTrade(1); // index out of bounds

        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctionKillTradeByTradeLauncher() public {
        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        // killTrade should not be callable by just anyone
        vm.expectRevert(IFolio.Folio__Unauthorized.selector);
        folio.killTrade(0);

        vm.startPrank(tradeLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.TradeKilled(0);
        folio.killTrade(0);

        // next auction index should revert

        vm.expectRevert();
        folio.killTrade(1); // index out of bounds

        (, , , , , , , , , uint256 end, ) = folio.trades(0);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctionKillTradeByOwner() public {
        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit IFolio.TradeKilled(0);
        folio.killTrade(0);

        // next auction index should revert

        vm.expectRevert();
        folio.killTrade(1); // index out of bounds

        (, , , , , , , , , uint256 end, ) = folio.trades(0);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctionAboveMaxTTL() public {
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidTradeTTL.selector);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL + 1);
    }

    function test_auctionNotOpenableUntilApproved() public {
        // should not be openable until approved

        vm.prank(dao);
        vm.expectRevert();
        folio.openTrade(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x
    }

    function test_auctionNotOpenableTwice() public {
        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, MAX_RATE, 1e27, 1e27);

        // Revert if tried to reopen
        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__TradeCannotBeOpened.selector);
        folio.openTrade(0, 0, MAX_RATE, 1e27, 1e27);
    }

    function test_auctionNotLaunchableAfterTimeout() public {
        vm.prank(dao);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TRADE_DELAY);

        // should not be openable after launchTimeout

        (, , , , , , , uint256 launchTimeout, , , ) = folio.trades(0);
        vm.warp(launchTimeout + 1);
        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__TradeTimeout.selector);
        folio.openTrade(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x
    }

    function test_auctionNotAvailableBeforeOpen() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        // auction should not be biddable before openTrade

        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
    }

    function test_auctionNotAvailableAfterEnd() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        folio.openTrade(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        // auction should not biddable after end

        (, , , , , , , , , uint256 end, ) = folio.trades(0);
        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__TradeNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
    }

    function test_auctionOnlyTradeLauncherCanBypassDelay() public {
        vm.startPrank(dao);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(1, 1), MAX_TTL);

        // dao should not be able to open trade because not tradeLauncher

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                dao,
                folio.TRADE_LAUNCHER()
            )
        );
        folio.openTrade(0, 0, MAX_RATE, 1, 1); // 10x -> 1x

        vm.expectRevert(IFolio.Folio__TradeCannotBeOpenedPermissionlesslyYet.selector);
        folio.openTradePermissionlessly(0);

        // but should be possible after trading delay

        (, , , , , , uint256 availableAt, , , , ) = folio.trades(0);
        vm.warp(availableAt);
        folio.openTradePermissionlessly(0);
        vm.stopPrank();
    }

    function test_permissionlessAuctionNotAvailableForZeroPricedTrades() public {
        vm.startPrank(dao);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(1e27, 1e27), MAX_TTL);

        // dao should not be able to open trade because not tradeLauncher

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                dao,
                folio.TRADE_LAUNCHER()
            )
        );
        folio.openTrade(0, 0, MAX_RATE, 1e27, 1e27);

        vm.expectRevert(IFolio.Folio__TradeCannotBeOpenedPermissionlesslyYet.selector);
        folio.openTradePermissionlessly(0);

        // but should be possible after trading delay

        (, , , , , , uint256 availableAt, , , , ) = folio.trades(0);
        vm.warp(availableAt);
        folio.openTradePermissionlessly(0);
        vm.stopPrank();
    }

    function test_auctionDishonestCallback() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        folio.openTrade(0, 0, MAX_RATE, 1e27, 1e27); // 1x

        // dishonest callback that returns fewer tokens than expected

        MockBidder mockBidder = new MockBidder(false);
        USDT.transfer(address(mockBidder), amt);
        vm.prank(address(mockBidder));
        vm.expectRevert(abi.encodeWithSelector(IFolio.Folio__InsufficientBid.selector));
        folio.bid(0, amt, amt, true, bytes(""));
    }

    function test_parallelAuctionsOnBuyToken() public {
        // launch two auction in parallel to sell ALL USDC/DAI

        uint256 amt1 = USDC.balanceOf(address(folio));
        uint256 amt2 = DAI.balanceOf(address(folio));
        vm.prank(dao);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);
        vm.prank(dao);
        folio.approveTrade(DAI, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        folio.openTrade(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x
        vm.prank(tradeLauncher);
        folio.openTrade(1, 0, MAX_RATE, 100e6, 1e6); // 100x -> 1x

        // bid in first auction for half volume at start

        vm.startPrank(user1);
        USDT.approve(address(folio), amt1 * 5);
        folio.bid(0, amt1 / 2, amt1 * 5, false, bytes(""));

        // advance halfway and bid for full volume of second auction

        (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(0);
        vm.warp(start + (end - start) / 2);
        uint256 bidAmt = (amt2 * 40) / 1e12; // adjust for decimals
        USDT.approve(address(folio), bidAmt);
        folio.bid(1, amt2, bidAmt, false, bytes("")); // ~31.6x

        // advance to end and bid for rest of first auction

        vm.warp(end);
        USDT.approve(address(folio), amt1 / 2);
        folio.bid(0, amt1 / 2, amt1 / 2, false, bytes(""));

        // auctions are over, should have no USDC + DAI left

        assertEq(folio.lot(0, end), 0, "unfinished auction 1");
        assertEq(folio.lot(1, start + (end - start) / 2), 0, "unfinished auction 2");
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        assertEq(DAI.balanceOf(address(folio)), 0, "wrong dai balance");
    }

    function test_parallelAuctionsOnSellToken() public {
        vm.startPrank(dao);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);
        folio.approveTrade(DAI, USDC, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);
        folio.approveTrade(USDC, DAI, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);
        folio.approveTrade(USDT, DAI, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.startPrank(tradeLauncher);
        folio.openTrade(0, 0, MAX_RATE, 1e27, 1e27);

        // trade 2 should be launchable
        vm.expectRevert(IFolio.Folio__TradeCollision.selector);
        folio.openTrade(1, 0, MAX_RATE, 1e27, 1e27);
        folio.openTrade(2, 0, MAX_RATE, 1e27, 1e27);
        vm.expectRevert(IFolio.Folio__TradeCollision.selector);
        folio.openTrade(3, 0, MAX_RATE, 1e27, 1e27);
    }

    function test_auctionPriceRange() public {
        for (uint256 i = MAX_RATE; i > 0; i /= 10) {
            uint256 index = folio.nextTradeId();

            vm.prank(dao);
            folio.approveTrade(MEME, USDC, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

            // should not revert at top or bottom end
            vm.prank(tradeLauncher);
            uint256 endPrice = i / MAX_PRICE_RANGE;
            folio.openTrade(index, 0, MAX_RATE, i, endPrice > i ? endPrice : i);
            (, , , , , , , , uint256 start, uint256 end, ) = folio.trades(index);
            folio.getPrice(index, start);
            folio.getPrice(index, end);
            vm.warp(end + 1);
        }
    }

    function test_priceCalculationGasCost() public {
        vm.prank(dao);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        folio.openTrade(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x
        (, , , , , , , , , uint256 end, ) = folio.trades(0);

        vm.startSnapshotGas("getPrice()");
        folio.getPrice(0, end);
        vm.stopSnapshotGas();
    }

    function test_upgrade() public {
        // Deploy and register new factory with version 2.0.0
        FolioDeployer newDeployerV2 = new FolioDeployerV2(
            address(daoFeeRegistry),
            address(versionRegistry),
            governanceDeployer
        );
        versionRegistry.registerVersion(newDeployerV2);

        // Check implementation for new version
        bytes32 newVersion = keccak256("2.0.0");
        address impl = versionRegistry.getImplementationForVersion(newVersion);
        assertEq(impl, newDeployerV2.folioImplementation());

        // Check current version
        assertEq(folio.version(), "1.0.0");

        // upgrade to V2 with owner
        vm.prank(owner);
        proxyAdmin.upgradeToVersion(address(folio), keccak256("2.0.0"), "");
        assertEq(folio.version(), "2.0.0");
    }

    function test_cannotUpgradeToVersionNotInRegistry() public {
        // Check current version
        assertEq(folio.version(), "1.0.0");

        // Attempt to upgrade to V2 (not registered)
        vm.prank(owner);
        vm.expectRevert();
        proxyAdmin.upgradeToVersion(address(folio), keccak256("2.0.0"), "");

        // still on old version
        assertEq(folio.version(), "1.0.0");
    }

    function test_cannotUpgradeToDeprecatedVersion() public {
        // Deploy and register new factory with version 2.0.0
        FolioDeployer newDeployerV2 = new FolioDeployerV2(
            address(daoFeeRegistry),
            address(versionRegistry),
            governanceDeployer
        );
        versionRegistry.registerVersion(newDeployerV2);

        // deprecate version
        versionRegistry.deprecateVersion(keccak256("2.0.0"));

        // Check current version
        assertEq(folio.version(), "1.0.0");

        // Attempt to upgrade to V2 (deprecated)
        vm.prank(owner);
        vm.expectRevert(FolioProxyAdmin.VersionDeprecated.selector);
        proxyAdmin.upgradeToVersion(address(folio), keccak256("2.0.0"), "");

        // still on old version
        assertEq(folio.version(), "1.0.0");
    }

    function test_cannotUpgradeIfNotOwnerOfProxyAdmin() public {
        // Deploy and register new factory with version 2.0.0
        FolioDeployer newDeployerV2 = new FolioDeployerV2(
            address(daoFeeRegistry),
            address(versionRegistry),
            governanceDeployer
        );
        versionRegistry.registerVersion(newDeployerV2);

        // Attempt to upgrade to V2 with random user
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        proxyAdmin.upgradeToVersion(address(folio), keccak256("2.0.0"), "");
    }

    function test_cannotCallAnyOtherFunctionFromProxyAdmin() public {
        // Attempt to call other functions in folio from ProxyAdmin
        vm.prank(address(proxyAdmin));
        vm.expectRevert(abi.encodeWithSelector(FolioProxy.ProxyDeniedAdminAccess.selector));
        folio.version();
    }

    function test_cannotUpgradeFolioDirectly() public {
        // Deploy and register new factory with version 2.0.0
        FolioDeployer newDeployerV2 = new FolioDeployerV2(
            address(daoFeeRegistry),
            address(versionRegistry),
            governanceDeployer
        );
        versionRegistry.registerVersion(newDeployerV2);

        // Get implementation for new version
        bytes32 newVersion = keccak256("2.0.0");
        address impl = versionRegistry.getImplementationForVersion(newVersion);
        assertEq(impl, newDeployerV2.folioImplementation());

        // Attempt to upgrade to V2 directly on the proxy
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(folio)).upgradeToAndCall(impl, "");
    }

    function test_auctionCannotBidIfExceedsSlippage() public {
        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, MAX_RATE, 1e27, 1e27);

        // bid once at start time
        vm.startPrank(user1);
        USDT.approve(address(folio), amt);
        vm.expectRevert(IFolio.Folio__SlippageExceeded.selector);
        folio.bid(0, amt, 1, false, bytes(""));
    }

    function test_auctionCannotBidWithInsufficientBalance() public {
        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, MAX_RATE, 1e27, 1e27);

        // bid once at start time
        vm.startPrank(user1);
        USDT.approve(address(folio), amt + 1);
        vm.expectRevert(IFolio.Folio__InsufficientBalance.selector);
        folio.bid(0, amt + 1, amt + 1, false, bytes("")); // no balance
    }

    function test_auctionCannotBidWithExcessiveBid() public {
        IFolio.Range memory buyLimit = IFolio.Range(1, 1, 1);

        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: buyLimit,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.TradeOpened(0, tradeStruct);
        folio.openTrade(0, 0, 1, 1e18, 1e18);

        // bid once (excessive bid)
        vm.startPrank(user1);
        USDT.approve(address(folio), D6_TOKEN_10K);
        vm.expectRevert(IFolio.Folio__ExcessiveBid.selector);
        folio.bid(0, amt, D6_TOKEN_100K, false, bytes(""));
    }

    function test_auctionCannotApproveTradeWithInvalidTokens() public {
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidTradeTokens.selector);
        folio.approveTrade(IERC20(address(0)), USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidTradeTokens.selector);
        folio.approveTrade(USDC, IERC20(address(0)), FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);
    }

    function test_auctionCannotApproveTradeWithInvalidSellLimit() public {
        IFolio.Range memory sellLimit = IFolio.Range(1, 0, 0);

        vm.startPrank(dao);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.approveTrade(USDC, USDT, sellLimit, FULL_BUY, ZERO_PRICES, MAX_TTL);

        sellLimit = IFolio.Range(0, 1, 1);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.approveTrade(USDC, USDT, sellLimit, FULL_BUY, ZERO_PRICES, MAX_TTL);

        sellLimit = IFolio.Range(MAX_RATE + 1, MAX_RATE, MAX_RATE);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.approveTrade(USDC, USDT, sellLimit, FULL_BUY, ZERO_PRICES, MAX_TTL);

        sellLimit = IFolio.Range(MAX_RATE, MAX_RATE + 1, MAX_RATE);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.approveTrade(USDC, USDT, sellLimit, FULL_BUY, ZERO_PRICES, MAX_TTL);

        sellLimit = IFolio.Range(MAX_RATE, MAX_RATE, MAX_RATE + 1);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.approveTrade(USDC, USDT, sellLimit, FULL_BUY, ZERO_PRICES, MAX_TTL);
    }

    function test_auctionCannotApproveTradeWithInvalidBuyLimit() public {
        IFolio.Range memory buyLimit = IFolio.Range(MAX_RATE + 1, MAX_RATE + 1, MAX_RATE + 1);

        vm.startPrank(dao);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveTrade(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        buyLimit = IFolio.Range(0, 0, 0);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveTrade(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        buyLimit = IFolio.Range(1, 0, 0);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveTrade(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        buyLimit = IFolio.Range(1, 1, 0);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveTrade(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        buyLimit = IFolio.Range(MAX_RATE, MAX_RATE + 1, MAX_RATE);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveTrade(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        buyLimit = IFolio.Range(MAX_RATE, MAX_RATE, MAX_RATE + 1);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveTrade(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);
    }

    function test_auctionCannotApproveTradeWithInvalidPrices() public {
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(0, 1), MAX_TTL);
    }

    function test_auctionCannotApproveTradeIfFolioKilled() public {
        vm.prank(owner);
        folio.killFolio();

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__FolioKilled.selector);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(0, 1), MAX_TTL);
    }

    function test_auctionCannotOpenTradeWithInvalidPrices() public {
        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(1e27, 1e27), MAX_TTL);

        //  Revert if tried to open (smaller start price)
        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openTrade(0, 0, MAX_RATE, 0.5e27, 1e27);

        //  Revert if tried to open (smaller end price)
        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openTrade(0, 0, MAX_RATE, 1e27, 0.5e27);

        //  Revert if tried to open (more than 100x start price)
        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openTrade(0, 0, MAX_RATE, 101e27, 50e27);

        //  Revert if tried to open (start < end price)
        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openTrade(0, 0, MAX_RATE, 50e27, 55e27);
    }

    function test_auctionCannotOpenTradeWithInvalidSellLimit() public {
        IFolio.Range memory sellLimit = IFolio.Range(1, 1, MAX_RATE - 1);
        vm.prank(dao);
        folio.approveTrade(USDC, USDT, sellLimit, FULL_BUY, IFolio.Prices(0, 0), MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.openTrade(0, 0, MAX_RATE, 1e27, 1e27);

        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.openTrade(0, MAX_RATE, MAX_RATE, 1e27, 1e27);
    }

    function test_auctionCannotOpenTradeWithInvalidBuyLimit() public {
        IFolio.Range memory buyLimit = IFolio.Range(1, 1, MAX_RATE - 1);
        vm.prank(dao);
        folio.approveTrade(USDC, USDT, FULL_SELL, buyLimit, IFolio.Prices(0, 0), MAX_TTL);

        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.openTrade(0, MAX_RATE, 0, 1e27, 1e27);

        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.openTrade(0, MAX_RATE, MAX_RATE, 1e27, 1e27);
    }

    function test_auctionCannotOpenTradeWithZeroPrice() public {
        IFolio.Trade memory tradeStruct = IFolio.Trade({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.tradeDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.TradeApproved(0, address(USDC), address(USDT), tradeStruct);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        //  Revert if tried to open with zero price
        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openTrade(0, 0, MAX_RATE, 0, 0);
    }

    function test_auctionCannotOpenTradeIfFolioKilled() public {
        vm.prank(dao);
        folio.approveTrade(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(0, 0), MAX_TTL);

        vm.prank(owner);
        folio.killFolio();

        vm.prank(tradeLauncher);
        vm.expectRevert(IFolio.Folio__FolioKilled.selector);
        folio.openTrade(0, 0, MAX_RATE, 1e27, 1e27);
    }

    function test_redeemMaxSlippage() public {
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);
        folio.mint(1e22, user1);
        assertEq(folio.balanceOf(user1), 1e22 - 1e22 / 2000, "wrong user1 balance");

        (address[] memory basket, uint256[] memory amounts) = folio.toAssets(5e21, Math.Rounding.Floor);

        amounts[0] += 1;
        vm.expectRevert(abi.encodeWithSelector(IFolio.Folio__InvalidAssetAmount.selector, basket[0]));
        folio.redeem(5e21, user1, basket, amounts);

        amounts[0] -= 1; // restore amounts
        basket[2] = address(USDT); // not in basket
        vm.expectRevert(IFolio.Folio__InvalidAsset.selector);
        folio.redeem(5e21, user1, basket, amounts);

        address[] memory smallerBasket = new address[](0);
        vm.expectRevert(IFolio.Folio__InvalidArrayLengths.selector);
        folio.redeem(5e21, user1, smallerBasket, amounts);
    }

    function test_killFolio() public {
        assertFalse(folio.isKilled(), "wrong killed status");

        vm.prank(owner);
        folio.killFolio();

        assertTrue(folio.isKilled(), "wrong killed status");
    }

    function test_cannotKillFolioIfNotOwner() public {
        assertFalse(folio.isKilled(), "wrong killed status");

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.killFolio();
        vm.stopPrank();
        assertFalse(folio.isKilled(), "wrong killed status");
    }

    function test_cannotAddZeroAddressToBasket() public {
        vm.startPrank(owner);
        vm.expectRevert(IFolio.Folio__InvalidAsset.selector);
        folio.addToBasket(IERC20(address(0)));
    }

    function test_poke() public {
        uint256 prevBlockTimestamp = folio.lastPoke();

        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        assertEq(folio.daoPendingFeeShares(), 0, "wrong dao pending fee shares");
        assertEq(folio.feeRecipientsPendingFeeShares(), 0, "wrong fee recipients pending fee shares");

        // call poke
        folio.poke();
        assertEq(folio.lastPoke(), block.timestamp);
        assertGt(block.timestamp, prevBlockTimestamp);

        // after poke
        assertEq(folio.daoPendingFeeShares(), 0, "wrong dao pending fee shares");
        assertEq(folio.feeRecipientsPendingFeeShares(), pendingFeeShares, "wrong fee recipients pending fee shares");

        // no-op if already poked
        folio.poke(); // collect shares
    }
}
