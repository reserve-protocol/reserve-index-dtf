// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio, MAX_AUCTION_LENGTH, MIN_AUCTION_LENGTH, MAX_AUCTION_DELAY, MAX_TTL, MAX_FEE_RECIPIENTS, MAX_TVL_FEE, MAX_MINT_FEE, MAX_PRICE_RANGE, MAX_RATE } from "contracts/Folio.sol";
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
    uint256 internal constant MAX_TVL_FEE_PER_SECOND = 3340960028; // D18{1/s} 10% annually, per second

    IFolio.BasketRange internal FULL_SELL = IFolio.BasketRange(0, 0, MAX_RATE);
    IFolio.BasketRange internal FULL_BUY = IFolio.BasketRange(MAX_RATE, 1, MAX_RATE);

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

        // 50% tvl fee annually
        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);
        MEME.approve(address(folioDeployer), type(uint256).max);

        (folio, proxyAdmin) = createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_AUCTION_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_TVL_FEE,
            0,
            owner,
            dao,
            auctionLauncher
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
        assertEq(folio.tvlFee(), MAX_TVL_FEE_PER_SECOND, "wrong tvl fee");
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
            auctionDelay: MAX_AUCTION_DELAY,
            auctionLength: MAX_AUCTION_LENGTH,
            feeRecipients: recipients,
            tvlFee: MAX_TVL_FEE,
            mintFee: 0,
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
            MAX_AUCTION_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_TVL_FEE,
            0,
            owner,
            dao,
            auctionLauncher
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

        // 50% tvl fee annually
        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        REENTRANT.approve(address(folioDeployer), type(uint256).max);

        (folio, proxyAdmin) = createFolio(
            tokens,
            amounts,
            INITIAL_SUPPLY,
            MAX_AUCTION_DELAY,
            MAX_AUCTION_LENGTH,
            recipients,
            MAX_TVL_FEE,
            0,
            owner,
            dao,
            auctionLauncher
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
        assertEq(folio.balanceOf(user1), 1e22 - (1e22 * 3) / 2000, "wrong user1 balance");
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

        // set mintFee to 5%
        vm.prank(owner);
        folio.setMintFee(MAX_MINT_FEE);
        // DAO cut is at 50%

        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);

        uint256 amt = 1e22;
        folio.mint(amt, user1);
        assertEq(folio.balanceOf(user1), amt - amt / 20, "wrong user1 balance");
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

        // mint fee should manifest in total supply and both streams of fee shares
        assertEq(folio.totalSupply(), amt * 2, "total supply off"); // genesis supply + new mint
        uint256 daoPendingFeeShares = (amt * MAX_MINT_FEE) / 1e18 / 2; // DAO receives 50% of the full mint fee
        assertEq(folio.daoPendingFeeShares(), daoPendingFeeShares, "wrong dao pending fee shares");
        assertEq(
            folio.feeRecipientsPendingFeeShares(),
            amt / 20 - daoPendingFeeShares,
            "wrong fee recipients pending fee shares"
        );
    }

    function test_mintWithFeeDAOCut() public {
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        uint256 startingUSDCBalance = USDC.balanceOf(address(folio));
        uint256 startingDAIBalance = DAI.balanceOf(address(folio));
        uint256 startingMEMEBalance = MEME.balanceOf(address(folio));

        // set mintFee to 5%
        vm.prank(owner);
        folio.setMintFee(MAX_MINT_FEE);
        daoFeeRegistry.setDefaultFeeNumerator(MAX_DAO_FEE); // DAO fee 50%

        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);

        uint256 amt = 1e22;
        folio.mint(amt, user1);
        assertEq(folio.balanceOf(user1), amt - amt / 20, "wrong user1 balance");
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
        assertEq(folio.totalSupply(), amt * 2, "total supply off"); // genesis supply + new mint + 5% increase
        uint256 daoPendingFeeShares = (amt / 20) / 2;
        assertEq(folio.daoPendingFeeShares(), daoPendingFeeShares, "wrong dao pending fee shares"); // only 15 bps
        assertEq(
            folio.feeRecipientsPendingFeeShares(),
            amt / 20 - daoPendingFeeShares,
            "wrong fee recipients pending fee shares"
        );
    }

    function test_mintWithFeeDAOCutFloor() public {
        // in this testcase the fee recipients receive 0 even though a tvlFee is nonzero
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        uint256 startingUSDCBalance = USDC.balanceOf(address(folio));
        uint256 startingDAIBalance = DAI.balanceOf(address(folio));
        uint256 startingMEMEBalance = MEME.balanceOf(address(folio));

        uint256 defaultFeeFloor = daoFeeRegistry.defaultFeeFloor();

        // set mintingFee to feeFloor, 15 bps
        vm.prank(owner);
        folio.setMintFee(defaultFeeFloor);
        // leave daoFeeRegistry fee at 0 (default)

        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);

        uint256 amt = 1e22;
        folio.mint(amt, user1);
        assertEq(folio.balanceOf(user1), amt - (amt * defaultFeeFloor) / 1e18, "wrong user1 balance");
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

        // mint fee should be manifested in total supply and ONLY the DAO's side of the stream
        assertEq(folio.totalSupply(), amt * 2, "total supply off");
        assertEq(folio.daoPendingFeeShares(), (amt * defaultFeeFloor) / 1e18, "wrong dao pending fee shares");
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
        assertEq(folio.balanceOf(user1), 1e22 - (1e22 * 3) / 2000, "wrong user1 balance");
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

        // validate pending fees have been accumulated -- 5% fee = ~11.1% of supply
        assertApproxEqAbs(supplyBefore, pendingFeeShares, 1.111e22, "wrong pending fee shares");

        uint256 initialOwnerShares = folio.balanceOf(owner);
        folio.distributeFees();

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = (pendingFeeShares * daoFeeNumerator + daoFeeDenominator - 1) /
            daoFeeDenominator +
            1;
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares");

        uint256 remainingShares = pendingFeeShares - expectedDaoShares;
        assertEq(
            folio.balanceOf(owner),
            initialOwnerShares + (remainingShares * 0.9e18 + 1e18 - 1) / 1e18,
            "wrong owner shares"
        );
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
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator, ) = daoFeeRegistry.getFeeDetails(address(folio));
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

    function test_setTvlFee() public {
        vm.startPrank(owner);
        assertEq(folio.tvlFee(), MAX_TVL_FEE_PER_SECOND, "wrong tvl fee");
        uint256 newTvlFee = MAX_TVL_FEE / 1000;
        uint256 newTvlFeePerSecond = 3171137;
        vm.expectEmit(true, true, false, true);
        emit IFolio.TVLFeeSet(newTvlFeePerSecond, MAX_TVL_FEE / 1000);
        folio.setTVLFee(newTvlFee);
        assertEq(folio.tvlFee(), newTvlFeePerSecond, "wrong tvl fee");
    }

    function test_setTVLFeeOutOfBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(IFolio.Folio__TVLFeeTooLow.selector);
        folio.setTVLFee(1);

        vm.expectRevert(IFolio.Folio__TVLFeeTooHigh.selector);
        folio.setTVLFee(MAX_TVL_FEE + 1);
    }

    function test_setAuctionDelay() public {
        vm.startPrank(owner);
        assertEq(folio.auctionDelay(), MAX_AUCTION_DELAY, "wrong auction delay");
        uint256 newAuctionDelay = 0;
        vm.expectEmit(true, true, false, true);
        emit IFolio.AuctionDelaySet(newAuctionDelay);
        folio.setAuctionDelay(newAuctionDelay);
        assertEq(folio.auctionDelay(), newAuctionDelay, "wrong auction delay");
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

    function test_setMintFee() public {
        vm.startPrank(owner);
        assertEq(folio.mintFee(), 0, "wrong mint fee");
        uint256 newMintFee = MAX_MINT_FEE;
        vm.expectEmit(true, true, false, true);
        emit IFolio.MintFeeSet(newMintFee);
        folio.setMintFee(newMintFee);
        assertEq(folio.mintFee(), newMintFee, "wrong mint fee");
    }

    function test_cannotSetMintFeeIfNotOwner() public {
        vm.startPrank(user1);
        uint256 newMintFee = MAX_MINT_FEE;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.setMintFee(newMintFee);
    }

    function test_setMintFee_InvalidFee() public {
        vm.startPrank(owner);
        uint256 newMintFee = MAX_MINT_FEE + 1;
        vm.expectRevert(IFolio.Folio__MintFeeTooHigh.selector);
        folio.setMintFee(newMintFee);
    }

    function test_cannotSetTVLFeeIfNotOwner() public {
        vm.startPrank(user1);
        uint256 newTVLFee = MAX_TVL_FEE / 1000;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.setTVLFee(newTVLFee);
    }

    function test_setTVLFee_DistributesFees() public {
        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS / 2);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();

        uint256 initialOwnerShares = folio.balanceOf(owner);
        uint256 initialDaoShares = folio.balanceOf(dao);

        vm.startPrank(owner);
        uint256 newTVLFee = MAX_TVL_FEE / 1000;
        folio.setTVLFee(newTVLFee);

        assertEq(folio.daoPendingFeeShares(), 0, "wrong dao pending fee shares");
        assertEq(folio.feeRecipientsPendingFeeShares(), 0, "wrong fee recipients pending fee shares");

        // check receipient balances
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator, ) = daoFeeRegistry.getFeeDetails(address(folio));
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

    function test_pendingFeeSharesAtFeeFloor() public {
        assertEq(folio.getPendingFeeShares(), 0, "pending fee shares should start 0");

        vm.prank(owner);
        folio.setTVLFee(0);

        // fast forward, accumulate fees
        vm.warp(block.timestamp + YEAR_IN_SECONDS);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();
        uint256 defaultFeeFloor = daoFeeRegistry.defaultFeeFloor();
        uint256 expectedPendingFeeShares = (INITIAL_SUPPLY * 1e18) / (1e18 - defaultFeeFloor) - INITIAL_SUPPLY;
        assertApproxEqAbs(
            pendingFeeShares,
            expectedPendingFeeShares,
            expectedPendingFeeShares / 1e7,
            "wrong pending fee shares"
        );
    }

    function test_setFeeRecipients_InvalidRecipient() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(address(0), 0.1e18);
        vm.expectRevert(IFolio.Folio__FeeRecipientInvalidAddress.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFeeRecipients_InvalidBps() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](1);
        //    recipients[0] = IFolio.FeeRecipient(owner, 0.1e18);
        recipients[0] = IFolio.FeeRecipient(feeReceiver, 0);
        vm.expectRevert(IFolio.Folio__FeeRecipientInvalidFeeShare.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFeeRecipients_InvalidTotal() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.0999e18);
        vm.expectRevert(IFolio.Folio__BadFeeTotal.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFeeRecipients_EmptyList() public {
        vm.startPrank(owner);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](0);
        vm.expectRevert(IFolio.Folio__BadFeeTotal.selector);
        folio.setFeeRecipients(recipients);
    }

    function test_setFeeRecipients_TooManyRecipients() public {
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

        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator, ) = daoFeeRegistry.getFeeDetails(address(folio));
        uint256 expectedDaoShares = initialDaoShares + (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator + 1;
        uint256 remainingShares = pendingFeeShares - expectedDaoShares;

        daoFeeRegistry.setTokenFeeNumerator(address(folio), 0.1e18);

        // check receipient balances
        assertEq(folio.balanceOf(address(dao)), expectedDaoShares, "wrong dao shares, 1st change");
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
        (, daoFeeNumerator, daoFeeDenominator, ) = daoFeeRegistry.getFeeDetails(address(folio));

        // set new fee numerator, should distribute fees
        daoFeeRegistry.setTokenFeeNumerator(address(folio), 0.05e18);

        // check receipient balances
        expectedDaoShares = (pendingFeeShares * daoFeeNumerator + daoFeeDenominator - 1) / daoFeeDenominator + 1;
        assertEq(folio.balanceOf(address(dao)), initialDaoShares + expectedDaoShares, "wrong dao shares, 2nd change");
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

        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });

        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27);

        // bid once at start time

        vm.startPrank(user1);
        USDT.approve(address(folio), amt);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, false, bytes(""));

        (, , , , , , , , uint256 start, uint256 end, ) = folio.auctions(0);
        assertEq(folio.getBid(0, start, amt), amt, "wrong start bid amount"); // 1x
        assertEq(folio.getBid(0, (start + end) / 2, amt), amt, "wrong mid bid amount"); // 1x
        assertEq(folio.getBid(0, end, amt), amt, "wrong end bid amount"); // 1x

        // bid a 2nd time for the rest of the volume, at end time
        vm.warp(end);
        USDT.approve(address(folio), amt);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();

        assertEq(folio.lot(0, block.timestamp), 0, "auction should be empty");
    }

    function test_atomicBidWithCallback() public {
        uint256 amt = D6_TOKEN_10K;
        // bid in two chunks, one at start time and one at end time
        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27);

        // bid once at start time

        MockBidder mockBidder = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder), amt / 2);
        vm.prank(address(mockBidder));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        (, , , , , , , , uint256 start, uint256 end, ) = folio.auctions(0);
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
        emit IFolio.AuctionBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder2)), 0, "wrong mock bidder2 balance");
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();

        assertEq(folio.lot(0, block.timestamp), 0, "auction should be empty");
    }

    function test_auctionBidWithoutCallback() public {
        // bid in two chunks, one at start time and one at end time

        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        // bid once at start time

        vm.startPrank(user1);
        USDT.approve(address(folio), amt * 5);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, amt / 2, amt * 5);
        folio.bid(0, amt / 2, amt * 5, false, bytes(""));

        (, , , , , , , , uint256 start, uint256 end, ) = folio.auctions(0);
        assertEq(folio.getBid(0, start, amt), amt * 10, "wrong start bid amount"); // 10x
        assertEq(folio.getBid(0, (start + end) / 2, amt), 31622776602, "wrong mid bid amount"); // ~3.16x
        assertEq(folio.getBid(0, end, amt), amt, "wrong end bid amount"); // 1x
        vm.warp(end);

        // bid a 2nd time for the rest of the volume, at end time
        USDT.approve(address(folio), amt);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionBidWithCallback() public {
        // bid in two chunks, one at start time and one at end time
        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });

        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        // bid once at start time

        MockBidder mockBidder = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder), amt * 5);
        vm.prank(address(mockBidder));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, amt / 2, amt * 5);
        folio.bid(0, amt / 2, amt * 5, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        // check prices

        (, , , , , , , , uint256 start, uint256 end, ) = folio.auctions(0);
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
        emit IFolio.AuctionBid(0, amt / 2, amt / 2);
        folio.bid(0, amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder2)), 0, "wrong mock bidder2 balance");
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionTinyPrices() public {
        // 1e-19 price

        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D27_TOKEN_1;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(MEME), address(USDT), auctionStruct);
        folio.approveAuction(MEME, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, MAX_RATE, 1e5, 1);

        // should have right bid at start, middle, and end of auction

        (, , , , , , , , uint256 start, uint256 end, ) = folio.auctions(0);
        assertEq(folio.getBid(0, start, amt), amt / 1e22, "wrong start bid amount");
        assertEq(folio.getBid(0, (start + end) / 2, amt), 316, "wrong mid bid amount");
        assertEq(folio.getBid(0, end, amt), 1, "wrong end bid amount");
    }

    function test_auctionCloseAuctionByAuctionApprover() public {
        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        // closeAuction should not be callable by just anyone
        vm.expectRevert(IFolio.Folio__Unauthorized.selector);
        folio.closeAuction(0);

        (, , , , , , , , , uint256 end, ) = folio.auctions(0);
        vm.startPrank(dao);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionClosed(0);
        folio.closeAuction(0);

        // next auction index should revert

        vm.expectRevert();
        folio.closeAuction(1); // index out of bounds

        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctioncloseAuctionByAuctionLauncher() public {
        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        // closeAuction should not be callable by just anyone
        vm.expectRevert(IFolio.Folio__Unauthorized.selector);
        folio.closeAuction(0);

        vm.startPrank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionClosed(0);
        folio.closeAuction(0);

        // next auction index should revert

        vm.expectRevert();
        folio.closeAuction(1); // index out of bounds

        (, , , , , , , , , uint256 end, ) = folio.auctions(0);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctioncloseAuctionByOwner() public {
        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionClosed(0);
        folio.closeAuction(0);

        // next auction index should revert

        vm.expectRevert();
        folio.closeAuction(1); // index out of bounds

        (, , , , , , , , , uint256 end, ) = folio.auctions(0);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctionAboveMaxTTL() public {
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidAuctionTTL.selector);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL + 1);
    }

    function test_auctionNotOpenableUntilApproved() public {
        // should not be openable until approved

        vm.prank(dao);
        vm.expectRevert();
        folio.openAuction(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x
    }

    function test_auctionNotOpenableTwice() public {
        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27);

        // Revert if tried to reopen
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__AuctionCannotBeOpened.selector);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27);
    }

    function test_auctionNotLaunchableAfterTimeout() public {
        vm.prank(dao);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_AUCTION_DELAY);

        // should not be openable after launchTimeout

        (, , , , , , , uint256 launchTimeout, , , ) = folio.auctions(0);
        vm.warp(launchTimeout + 1);
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__AuctionTimeout.selector);
        folio.openAuction(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x
    }

    function test_auctionNotAvailableBeforeOpen() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        // auction should not be biddable before openAuction

        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
    }

    function test_auctionNotAvailableAfterEnd() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        folio.openAuction(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x

        // auction should not biddable after end

        (, , , , , , , , , uint256 end, ) = folio.auctions(0);
        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, amt, amt, false, bytes(""));
    }

    function test_auctionOnlyAuctionLauncherCanBypassDelay() public {
        vm.startPrank(dao);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(1, 1), MAX_TTL);

        // dao should not be able to open auction because not auctionLauncher

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                dao,
                folio.AUCTION_LAUNCHER()
            )
        );
        folio.openAuction(0, 0, MAX_RATE, 1, 1); // 10x -> 1x

        vm.expectRevert(IFolio.Folio__AuctionCannotBeOpenedPermissionlesslyYet.selector);
        folio.openAuctionPermissionlessly(0);

        // but should be possible after auction delay

        (, , , , , , uint256 availableAt, , , , ) = folio.auctions(0);
        vm.warp(availableAt);
        folio.openAuctionPermissionlessly(0);
        vm.stopPrank();
    }

    function test_permissionlessAuctionNotAvailableForZeroPricedAuctions() public {
        vm.startPrank(dao);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(1e27, 1e27), MAX_TTL);

        // dao should not be able to open auction because not auctionLauncher

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                dao,
                folio.AUCTION_LAUNCHER()
            )
        );
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27);

        vm.expectRevert(IFolio.Folio__AuctionCannotBeOpenedPermissionlesslyYet.selector);
        folio.openAuctionPermissionlessly(0);

        // but should be possible after auction delay

        (, , , , , , uint256 availableAt, , , , ) = folio.auctions(0);
        vm.warp(availableAt);
        folio.openAuctionPermissionlessly(0);
        vm.stopPrank();
    }

    function test_auctionDishonestCallback() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27); // 1x

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
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);
        vm.prank(dao);
        folio.approveAuction(DAI, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        folio.openAuction(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x
        vm.prank(auctionLauncher);
        folio.openAuction(1, 0, MAX_RATE, 100e6, 1e6); // 100x -> 1x

        // bid in first auction for half volume at start

        vm.startPrank(user1);
        USDT.approve(address(folio), amt1 * 5);
        folio.bid(0, amt1 / 2, amt1 * 5, false, bytes(""));

        // advance halfway and bid for full volume of second auction

        (, , , , , , , , uint256 start, uint256 end, ) = folio.auctions(0);
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
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);
        folio.approveAuction(DAI, USDC, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);
        folio.approveAuction(USDC, DAI, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);
        folio.approveAuction(USDT, DAI, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.startPrank(auctionLauncher);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27);

        // auction 2 should be launchable
        vm.expectRevert(IFolio.Folio__AuctionCollision.selector);
        folio.openAuction(1, 0, MAX_RATE, 1e27, 1e27);
        folio.openAuction(2, 0, MAX_RATE, 1e27, 1e27);
        vm.expectRevert(IFolio.Folio__AuctionCollision.selector);
        folio.openAuction(3, 0, MAX_RATE, 1e27, 1e27);
    }

    function test_auctionPriceRange() public {
        for (uint256 i = MAX_RATE; i > 0; i /= 10) {
            uint256 index = folio.nextAuctionId();

            vm.prank(dao);
            folio.approveAuction(MEME, USDC, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

            // should not revert at top or bottom end
            vm.prank(auctionLauncher);
            uint256 endPrice = i / MAX_PRICE_RANGE;
            folio.openAuction(index, 0, MAX_RATE, i, endPrice > i ? endPrice : i);
            (, , , , , , , , uint256 start, uint256 end, ) = folio.auctions(index);
            folio.getPrice(index, start);
            folio.getPrice(index, end);
            vm.warp(end + 1);
        }
    }

    function test_priceCalculationGasCost() public {
        vm.prank(dao);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        folio.openAuction(0, 0, MAX_RATE, 10e27, 1e27); // 10x -> 1x
        (, , , , , , , , , uint256 end, ) = folio.auctions(0);

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
        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27);

        // bid once at start time
        vm.startPrank(user1);
        USDT.approve(address(folio), amt);
        vm.expectRevert(IFolio.Folio__SlippageExceeded.selector);
        folio.bid(0, amt, 1, false, bytes(""));
    }

    function test_auctionCannotBidWithInsufficientBalance() public {
        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27);

        // bid once at start time
        vm.startPrank(user1);
        USDT.approve(address(folio), amt + 1);
        vm.expectRevert(IFolio.Folio__InsufficientBalance.selector);
        folio.bid(0, amt + 1, amt + 1, false, bytes("")); // no balance
    }

    function test_auctionCannotBidWithExcessiveBid() public {
        IFolio.BasketRange memory buyLimit = IFolio.BasketRange(1, 1, 1);

        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: buyLimit,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        uint256 amt = D6_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(0, auctionStruct);
        folio.openAuction(0, 0, 1, 1e18, 1e18);

        // bid once (excessive bid)
        vm.startPrank(user1);
        USDT.approve(address(folio), D6_TOKEN_10K);
        vm.expectRevert(IFolio.Folio__ExcessiveBid.selector);
        folio.bid(0, amt, D6_TOKEN_100K, false, bytes(""));
    }

    function test_auctionCannotApproveAuctionWithInvalidTokens() public {
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidAuctionTokens.selector);
        folio.approveAuction(IERC20(address(0)), USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidAuctionTokens.selector);
        folio.approveAuction(USDC, IERC20(address(0)), FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);
    }

    function test_auctionCannotApproveAuctionWithInvalidSellLimit() public {
        IFolio.BasketRange memory sellLimit = IFolio.BasketRange(1, 0, 0);

        vm.startPrank(dao);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.approveAuction(USDC, USDT, sellLimit, FULL_BUY, ZERO_PRICES, MAX_TTL);

        sellLimit = IFolio.BasketRange(0, 1, 1);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.approveAuction(USDC, USDT, sellLimit, FULL_BUY, ZERO_PRICES, MAX_TTL);

        sellLimit = IFolio.BasketRange(MAX_RATE + 1, MAX_RATE, MAX_RATE);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.approveAuction(USDC, USDT, sellLimit, FULL_BUY, ZERO_PRICES, MAX_TTL);

        sellLimit = IFolio.BasketRange(MAX_RATE, MAX_RATE + 1, MAX_RATE);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.approveAuction(USDC, USDT, sellLimit, FULL_BUY, ZERO_PRICES, MAX_TTL);

        sellLimit = IFolio.BasketRange(MAX_RATE, MAX_RATE, MAX_RATE + 1);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.approveAuction(USDC, USDT, sellLimit, FULL_BUY, ZERO_PRICES, MAX_TTL);
    }

    function test_auctionCannotApproveAuctionWithInvalidBuyLimit() public {
        IFolio.BasketRange memory buyLimit = IFolio.BasketRange(MAX_RATE + 1, MAX_RATE + 1, MAX_RATE + 1);

        vm.startPrank(dao);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveAuction(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        buyLimit = IFolio.BasketRange(0, 0, 0);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveAuction(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        buyLimit = IFolio.BasketRange(1, 0, 0);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveAuction(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        buyLimit = IFolio.BasketRange(1, 1, 0);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveAuction(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        buyLimit = IFolio.BasketRange(MAX_RATE, MAX_RATE + 1, MAX_RATE);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveAuction(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);

        buyLimit = IFolio.BasketRange(MAX_RATE, MAX_RATE, MAX_RATE + 1);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.approveAuction(USDC, USDT, FULL_SELL, buyLimit, ZERO_PRICES, MAX_TTL);
    }

    function test_auctionCannotApproveAuctionWithInvalidPrices() public {
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(0, 1), MAX_TTL);
    }

    function test_auctionCannotApproveAuctionIfFolioKilled() public {
        vm.prank(owner);
        folio.killFolio();

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__FolioKilled.selector);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(0, 1), MAX_TTL);
    }

    function test_auctionCannotOpenAuctionWithInvalidPrices() public {
        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(1e27, 1e27), MAX_TTL);

        //  Revert if tried to open (smaller start price)
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(0, 0, MAX_RATE, 0.5e27, 1e27);

        //  Revert if tried to open (smaller end price)
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 0.5e27);

        //  Revert if tried to open (more than 100x start price)
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(0, 0, MAX_RATE, 101e27, 50e27);

        //  Revert if tried to open (start < end price)
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(0, 0, MAX_RATE, 50e27, 55e27);
    }

    function test_auctionCannotOpenAuctionWithInvalidSellLimit() public {
        IFolio.BasketRange memory sellLimit = IFolio.BasketRange(1, 1, MAX_RATE - 1);
        vm.prank(dao);
        folio.approveAuction(USDC, USDT, sellLimit, FULL_BUY, IFolio.Prices(0, 0), MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27);

        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__InvalidSellLimit.selector);
        folio.openAuction(0, MAX_RATE, MAX_RATE, 1e27, 1e27);
    }

    function test_auctionCannotOpenAuctionWithInvalidBuyLimit() public {
        IFolio.BasketRange memory buyLimit = IFolio.BasketRange(1, 1, MAX_RATE - 1);
        vm.prank(dao);
        folio.approveAuction(USDC, USDT, FULL_SELL, buyLimit, IFolio.Prices(0, 0), MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.openAuction(0, MAX_RATE, 0, 1e27, 1e27);

        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__InvalidBuyLimit.selector);
        folio.openAuction(0, MAX_RATE, MAX_RATE, 1e27, 1e27);
    }

    function test_auctionCannotOpenAuctionWithZeroPrice() public {
        IFolio.Auction memory auctionStruct = IFolio.Auction({
            id: 0,
            sell: USDC,
            buy: USDT,
            sellLimit: FULL_SELL,
            buyLimit: FULL_BUY,
            prices: ZERO_PRICES,
            availableAt: block.timestamp + folio.auctionDelay(),
            launchTimeout: block.timestamp + MAX_TTL,
            start: 0,
            end: 0,
            k: 0
        });
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionApproved(0, address(USDC), address(USDT), auctionStruct);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, ZERO_PRICES, MAX_TTL);

        //  Revert if tried to open with zero price
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(0, 0, MAX_RATE, 0, 0);
    }

    function test_auctionCannotOpenAuctionIfFolioKilled() public {
        vm.prank(dao);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(0, 0), MAX_TTL);

        vm.prank(owner);
        folio.killFolio();

        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__FolioKilled.selector);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27);
    }

    function test_auctionCannotBidIfFolioKilled() public {
        vm.prank(dao);
        folio.approveAuction(USDC, USDT, FULL_SELL, FULL_BUY, IFolio.Prices(0, 0), MAX_TTL);

        vm.prank(auctionLauncher);
        folio.openAuction(0, 0, MAX_RATE, 1e27, 1e27);

        vm.prank(owner);
        folio.killFolio();

        vm.expectRevert(IFolio.Folio__FolioKilled.selector);
        folio.bid(0, 1e27, 1e27, false, bytes(""));
        assertEq(folio.isKilled(), true, "wrong killed status");
    }

    function test_redeemMaxSlippage() public {
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);
        folio.mint(1e22, user1);
        assertEq(folio.balanceOf(user1), 1e22 - (1e22 * 3) / 2000, "wrong user1 balance");

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
        // call poke
        folio.poke();
        assertEq(folio.lastPoke(), block.timestamp);
        vm.warp(block.timestamp + 1000);

        // no-op if already poked
        vm.startSnapshotGas("poke()");
        folio.poke(); // collect shares
        vm.stopSnapshotGas("poke()");

        // no-op if already poked
        vm.startSnapshotGas("repeat poke()");
        folio.poke(); // collect shares
        vm.stopSnapshotGas("repeat poke()");
    }
}
