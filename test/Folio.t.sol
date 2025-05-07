// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IBaseTrustedFiller } from "@reserve-protocol/trusted-fillers/contracts/interfaces/IBaseTrustedFiller.sol";
import { GPv2OrderLib } from "@reserve-protocol/trusted-fillers/contracts/fillers/cowswap/GPv2OrderLib.sol";
import { GPV2_SETTLEMENT } from "@reserve-protocol/trusted-fillers/contracts/fillers/cowswap/Constants.sol";
import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio } from "contracts/Folio.sol";
import { D27, MIN_AUCTION_LENGTH, MAX_AUCTION_LENGTH, MAX_MINT_FEE, MAX_AUCTION_DELAY, MAX_TTL, MAX_FEE_RECIPIENTS, MAX_TOKEN_PRICE, MAX_TOKEN_PRICE_RANGE, MAX_TVL_FEE, MAX_LIMIT, MAX_WEIGHT, RESTRICTED_AUCTION_BUFFER } from "@utils/Constants.sol";
import { MAX_DAO_FEE } from "contracts/folio/FolioDAOFeeRegistry.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FolioProxyAdmin, FolioProxy } from "contracts/folio/FolioProxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { FolioDeployerV2 } from "test/utils/upgrades/FolioDeployerV2.sol";
import { MockEIP712 } from "test/utils/MockEIP712.sol";
import "./base/BaseTest.sol";

contract FolioTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;
    uint256 internal constant MAX_TVL_FEE_PER_SECOND = 3340960028; // D18{1/s} 10% annually, per second
    uint256 internal constant AUCTION_LAUNCHER_WINDOW = MAX_TTL / 2;

    IFolio.WeightRange internal REMOVE = IFolio.WeightRange(0, 0, 0);
    IFolio.WeightRange internal BUY = IFolio.WeightRange(MAX_WEIGHT, 1, MAX_WEIGHT);

    IFolio.WeightRange internal WEIGHTS_6 = IFolio.WeightRange(1e15, 1, MAX_WEIGHT); // D27{tok/BU}
    IFolio.WeightRange internal WEIGHTS_18 = IFolio.WeightRange(1e27, 1, MAX_WEIGHT); // D27{tok/BU}
    IFolio.WeightRange internal WEIGHTS_27 = IFolio.WeightRange(1e36, 1, MAX_WEIGHT); // D27{tok/BU}

    IFolio.PriceRange internal FULL_PRICE_RANGE_6 = IFolio.PriceRange(1e20, 1e22); // D27{UoA/tok}
    IFolio.PriceRange internal FULL_PRICE_RANGE_18 = IFolio.PriceRange(1e8, 1e10); // D27{UoA/tok}
    IFolio.PriceRange internal FULL_PRICE_RANGE_27 = IFolio.PriceRange(1, 100); // D27{UoA/tok} worth $10 not $1

    IFolio.PriceRange internal HALF_PRICE_RANGE_6 = IFolio.PriceRange(1e20, 1e21); // D27{UoA/tok}
    IFolio.PriceRange internal HALF_PRICE_RANGE_18 = IFolio.PriceRange(1e8, 1e9); // D27{UoA/tok}
    IFolio.PriceRange internal HALF_PRICE_RANGE_27 = IFolio.PriceRange(1, 10); // D27{UoA/tok}

    IFolio.PriceRange internal PRICE_POINT_6 = IFolio.PriceRange(1e21, 1e21); // D27{UoA/tok}
    IFolio.PriceRange internal PRICE_POINT_18 = IFolio.PriceRange(1e9, 1e9); // D27{UoA/tok}
    IFolio.PriceRange internal PRICE_POINT_27 = IFolio.PriceRange(1, 1); // D27{UoA/tok}

    uint256 internal constant ONE_BU = 1e18;

    address[] assets;
    IFolio.WeightRange[] weights;
    IFolio.PriceRange[] prices;
    IFolio.RebalanceLimits limits = IFolio.RebalanceLimits({ spot: ONE_BU, low: 1, high: MAX_LIMIT });

    function _testSetup() public virtual override {
        super._testSetup();
        _deployTestFolio();
    }

    function _deployTestFolio() public {
        assets.push(address(USDC));
        assets.push(address(DAI));
        assets.push(address(MEME));
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = D6_TOKEN_10K;
        amounts[1] = D18_TOKEN_10K;
        amounts[2] = D27_TOKEN_10K;
        weights.push(WEIGHTS_6);
        weights.push(WEIGHTS_18);
        weights.push(WEIGHTS_27);
        prices.push(FULL_PRICE_RANGE_6);
        prices.push(FULL_PRICE_RANGE_18);
        prices.push(FULL_PRICE_RANGE_27);
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](2);
        recipients[0] = IFolio.FeeRecipient(owner, 0.9e18);
        recipients[1] = IFolio.FeeRecipient(feeReceiver, 0.1e18);

        // 50% tvl fee annually
        vm.startPrank(owner);
        USDC.approve(address(folioDeployer), type(uint256).max);
        DAI.approve(address(folioDeployer), type(uint256).max);
        MEME.approve(address(folioDeployer), type(uint256).max);

        (folio, proxyAdmin) = createFolio(
            assets,
            amounts,
            INITIAL_SUPPLY,
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
        assertEq(folio.version(), VERSION);
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
        address folioImplementation = versionRegistry.getImplementationForVersion(keccak256(bytes(VERSION)));
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
            auctionLength: MAX_AUCTION_LENGTH,
            feeRecipients: recipients,
            tvlFee: MAX_TVL_FEE,
            mintFee: 0,
            mandate: "mandate"
        });

        IFolio.FolioRegistryIndex memory registryIndex = IFolio.FolioRegistryIndex({
            daoFeeRegistry: address(daoFeeRegistry),
            trustedFillerRegistry: address(trustedFillerRegistry)
        });

        IFolio.FolioRegistryFlags memory registryFlags = IFolio.FolioRegistryFlags({ trustedFillerEnabled: true });

        // Attempt to initialize
        vm.expectRevert(IFolio.Folio__InvalidAsset.selector);
        newFolio.initialize(basicDetails, additionalDetails, registryIndex, registryFlags, address(this));
    }

    function test_cannotCreateWithZeroInitialShares() public {
        address[] memory _tokens = new address[](2);
        _tokens[0] = address(USDC);
        _tokens[1] = address(DAI);
        uint256[] memory _amounts = new uint256[](2);
        _amounts[0] = D6_TOKEN_10K;
        _amounts[1] = D18_TOKEN_10K;
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
            _tokens,
            _amounts,
            0, // zero initial shares
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
        (address[] memory _assets, uint256[] memory _amounts) = folio.toAssets(1e18, Math.Rounding.Floor);
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

    function test_mint() public {
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        uint256 startingUSDCBalance = USDC.balanceOf(address(folio));
        uint256 startingDAIBalance = DAI.balanceOf(address(folio));
        uint256 startingMEMEBalance = MEME.balanceOf(address(folio));
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);
        folio.mint(1e22, user1, 0);
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

    function test_mintSlippageLimits() public {
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);

        // should revert since there are fees applied
        vm.expectRevert(IFolio.Folio__InsufficientSharesOut.selector);
        folio.mint(1e22, user1, 1e22);
        vm.expectRevert(IFolio.Folio__InsufficientSharesOut.selector);
        folio.mint(1e22, user1, 1e22 - (1e22 * 3) / 2000 + 1);

        // should succeed
        folio.mint(1e22, user1, 1e22 - (1e22 * 3) / 2000);
    }

    function test_mintZero() public {
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);

        // should revert since there are fees applied
        vm.expectRevert(IFolio.Folio__InsufficientSharesOut.selector);
        folio.mint(1, user1, 0);
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
        folio.mint(amt, user1, 0);
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
        folio.mint(amt, user1, 0);
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
        folio.mint(amt, user1, 0);
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

    function test_cannotMintIfFolioDeprecated() public {
        vm.prank(owner);
        folio.deprecateFolio();

        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IFolio.Folio__FolioDeprecated.selector));
        folio.mint(1e22, user1, 0);
        vm.stopPrank();
        assertEq(folio.balanceOf(user1), 0, "wrong ending user1 balance");
    }

    function test_redeem() public {
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);
        folio.mint(1e22, user1, 0);
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

        // should not be able to remove from basket when balance is nonzero

        vm.prank(user1);
        vm.expectRevert(IFolio.Folio__BalanceNotRemovable.selector);
        folio.removeFromBasket(MEME);
        MockERC20(address(MEME)).burn(address(folio), MEME.balanceOf(address(folio)) - 1);
        vm.expectRevert(IFolio.Folio__BalanceNotRemovable.selector);
        folio.removeFromBasket(MEME);

        // should be able to remove at 0 balance

        MockERC20(address(MEME)).burn(address(folio), 1);

        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit IFolio.BasketTokenRemoved(address(MEME));
        folio.removeFromBasket(MEME);

        (_assets, ) = folio.totalAssets();
        assertEq(_assets.length, 2, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
    }

    function test_removeFromBasketByOwner() public {
        (address[] memory _assets, ) = folio.totalAssets();
        assertEq(_assets.length, 3, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
        assertEq(_assets[2], address(MEME), "wrong third asset");

        // should be able to remove at any balance by owner

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IFolio.BasketTokenRemoved(address(MEME));
        folio.removeFromBasket(MEME);

        (_assets, ) = folio.totalAssets();
        assertEq(_assets.length, 2, "wrong assets length");
        assertEq(_assets[0], address(USDC), "wrong first asset");
        assertEq(_assets[1], address(DAI), "wrong second asset");
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
        emit IFolio.FeeRecipientsSet(recipients);
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
        emit IFolio.FeeRecipientsSet(recipients);
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

        vm.warp(2 days);
        folio.distributeFees();

        uint256 initialSupply = folio.totalSupply();

        vm.warp(block.timestamp + YEAR_IN_SECONDS);
        vm.roll(block.number + 1000000);
        uint256 pendingFeeShares = folio.getPendingFeeShares();
        uint256 defaultFeeFloor = daoFeeRegistry.defaultFeeFloor();
        uint256 expectedPendingFeeShares = (initialSupply * 1e18) / (1e18 - defaultFeeFloor) - initialSupply;
        assertApproxEqRel(pendingFeeShares, expectedPendingFeeShares, 5e10, "wrong pending fee shares");
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
        vm.expectEmit(true, true, false, true);
        emit IFolio.FeeRecipientsSet(new IFolio.FeeRecipient[](0));
        folio.setFeeRecipients(new IFolio.FeeRecipient[](0));
        vm.stopPrank();

        vm.expectRevert();
        folio.feeRecipients(0);

        // distributeFees should give all fees to DAO

        vm.warp(block.timestamp + YEAR_IN_SECONDS);
        vm.roll(block.number + 1);

        folio.distributeFees();
        assertEq(folio.getPendingFeeShares(), 0);
        assertApproxEqRel(folio.balanceOf(dao), (INITIAL_SUPPLY * 0.1111e18) / 1e18, 0.001e18);
        assertEq(folio.balanceOf(feeReceiver), 0);
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

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = REMOVE;
        prices[0] = PRICE_POINT_6;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(PRICE_POINT_6);

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_DELAY);

        uint256[] memory auctionWeights = new uint256[](weights.length);
        for (uint256 i = 0; i < weights.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // bid once at start time

        vm.startPrank(user1);
        USDT.approve(address(folio), amt);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt / 2);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt / 2, amt / 2, false, bytes(""));

        (, , , uint256 start, uint256 end) = folio.auctions(0);
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            start,
            amt
        );
        assertEq(sellAmount, amt / 2, "wrong start sell amount");
        assertEq(buyAmount, amt / 2, "wrong start buy amount");

        (sellAmount, buyAmount, ) = folio.getBid(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            (start + end) / 2,
            amt
        );
        assertEq(sellAmount, amt / 2, "wrong mid sell amount");
        assertEq(buyAmount, amt / 2, "wrong mid buy amount");

        (sellAmount, buyAmount, ) = folio.getBid(0, IERC20(address(USDC)), IERC20(address(USDT)), end, amt);
        assertEq(sellAmount, amt / 2, "wrong end sell amount");
        assertEq(buyAmount, amt / 2, "wrong end buy amount");

        // bid a 2nd time for the rest of the volume, at end time
        vm.warp(end);
        USDT.approve(address(folio), amt);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt / 2);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt / 2, amt / 2, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_atomicBidWithCallback() public {
        uint256 amt = D6_TOKEN_10K;
        // bid in two chunks, one at start time and one at end time

        // Sell USDC
        weights[0] = REMOVE;
        prices[0] = PRICE_POINT_6;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(PRICE_POINT_6);

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_DELAY);

        uint256[] memory auctionWeights = new uint256[](weights.length);
        for (uint256 i = 0; i < weights.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // bid once at start time

        MockBidder mockBidder = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder), amt / 2);
        vm.prank(address(mockBidder));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt / 2);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        (, , , uint256 start, uint256 end) = folio.auctions(0);

        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            start,
            amt
        );
        assertEq(sellAmount, amt / 2, "wrong start sell amount");
        assertEq(buyAmount, amt / 2, "wrong start buy amount");

        (sellAmount, buyAmount, ) = folio.getBid(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            (start + end) / 2,
            amt
        );
        assertEq(sellAmount, amt / 2, "wrong mid sell amount");
        assertEq(buyAmount, amt / 2, "wrong mid buy amount");

        (sellAmount, buyAmount, ) = folio.getBid(0, IERC20(address(USDC)), IERC20(address(USDT)), end, amt);
        assertEq(sellAmount, amt / 2, "wrong end sell amount");
        assertEq(buyAmount, amt / 2, "wrong end buy amount");

        // bid a 2nd time for the rest of the volume, at end time

        vm.warp(end);
        MockBidder mockBidder2 = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder2), amt / 2);
        vm.prank(address(mockBidder2));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt / 2);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder2)), 0, "wrong mock bidder2 balance");
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionBidWithoutCallback() public {
        // bid in two chunks, one at start time and one at end time

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = REMOVE;
        prices[0] = PRICE_POINT_6;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(HALF_PRICE_RANGE_6);

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_DELAY);
        uint256[] memory auctionWeights = new uint256[](weights.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // bid once at start time

        vm.startPrank(user1);
        USDT.approve(address(folio), amt * 5);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt * 5);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt / 2, amt * 5, false, bytes(""));

        (, , , uint256 start, uint256 end) = folio.auctions(0);

        vm.startSnapshotGas("getBid()");
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            start,
            amt
        );
        vm.stopSnapshotGas();
        assertEq(sellAmount, amt / 2, "wrong start sell amount");
        assertEq(buyAmount, amt * 5, "wrong start buy amount"); // 10x

        (sellAmount, buyAmount, ) = folio.getBid(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            (start + end) / 2,
            amt
        );
        assertEq(sellAmount, amt / 2, "wrong mid sell amount");
        assertEq(buyAmount, 15811388301, "wrong mid buy amount"); // ~3.16x

        (sellAmount, buyAmount, ) = folio.getBid(0, IERC20(address(USDC)), IERC20(address(USDT)), end, amt);
        assertEq(sellAmount, amt / 2, "wrong end sell amount");
        assertEq(buyAmount, amt / 2, "wrong end buy amount"); // 1x

        // bid a 2nd time for the rest of the volume, at end time
        vm.warp(end);
        USDT.approve(address(folio), amt);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt / 2);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt / 2, amt / 2, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionBidWithCallback() public {
        // bid in two chunks, one at start time and one at end time

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = REMOVE;
        prices[0] = PRICE_POINT_6;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(HALF_PRICE_RANGE_6);

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_DELAY);
        uint256[] memory auctionWeights = new uint256[](weights.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // bid once at start time (10x)

        MockBidder mockBidder = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder), amt * 5);
        vm.prank(address(mockBidder));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt * 5);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt / 2, amt * 5, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        // check prices
        (, , , uint256 start, uint256 end) = folio.auctions(0);

        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            start,
            amt
        );
        assertEq(sellAmount, amt / 2, "wrong start sell amount");
        assertEq(buyAmount, amt * 5, "wrong start buy amount"); // 10x

        (sellAmount, buyAmount, ) = folio.getBid(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            (start + end) / 2,
            amt
        );
        assertEq(sellAmount, amt / 2, "wrong mid sell amount");
        assertEq(buyAmount, 15811388301, "wrong mid buy amount"); // ~3.16x

        (sellAmount, buyAmount, ) = folio.getBid(0, IERC20(address(USDC)), IERC20(address(USDT)), end, amt);
        assertEq(sellAmount, amt / 2, "wrong end sell amount");
        assertEq(buyAmount, amt / 2, "wrong end buy amount"); // 1x

        // bid a 2nd time for the rest of the volume, at end time

        vm.warp(end);
        MockBidder mockBidder2 = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder2), amt / 2);
        vm.prank(address(mockBidder2));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt / 2);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder2)), 0, "wrong mock bidder2 balance");
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionByMockFiller() public {
        // bid in two chunks, one at start time and one at end time

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = REMOVE;
        prices[0] = PRICE_POINT_6;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(HALF_PRICE_RANGE_6);

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );

        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_DELAY);
        uint256[] memory auctionWeights = new uint256[](weights.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // check prices
        (, , , uint256 start, uint256 end) = folio.auctions(0);

        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            start,
            amt
        );
        assertEq(sellAmount, amt, "wrong start sell amount");
        assertEq(buyAmount, amt * 10, "wrong start buy amount"); // 10x

        (sellAmount, buyAmount, ) = folio.getBid(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            (start + end) / 2,
            amt
        );
        assertEq(sellAmount, amt, "wrong mid sell amount");
        assertEq(buyAmount, 31622776602, "wrong mid buy amount"); // ~3.16x

        (sellAmount, buyAmount, ) = folio.getBid(0, IERC20(address(USDC)), IERC20(address(USDT)), end, amt);
        assertEq(sellAmount, amt, "wrong end sell amount");
        assertEq(buyAmount, amt, "wrong end buy amount"); // 1x

        // fill 1st time
        IBaseTrustedFiller fill = folio.createTrustedFill(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            cowswapFiller,
            bytes32(block.timestamp)
        );
        MockERC20(address(USDC)).burn(address(fill), amt / 2);
        MockERC20(address(USDT)).mint(address(fill), amt * 5);
        vm.warp(end);

        (sellAmount, buyAmount, ) = folio.getBid(0, IERC20(address(USDC)), IERC20(address(USDT)), start, amt);
        assertEq(sellAmount, amt / 2, "wrong start sell amount");
        assertEq(buyAmount, amt * 5, "wrong start buy amount"); // 10x

        (sellAmount, buyAmount, ) = folio.getBid(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            (start + end) / 2,
            amt
        );
        assertEq(sellAmount, amt / 2, "wrong mid sell amount");
        assertEq(buyAmount, 15811388301, "wrong mid buy amount"); // ~3.16x

        (sellAmount, buyAmount, ) = folio.getBid(0, IERC20(address(USDC)), IERC20(address(USDT)), end, amt);
        assertEq(sellAmount, amt / 2, "wrong end sell amount");
        assertEq(buyAmount, amt / 2, "wrong end buy amount"); // 1x

        // bid a 2nd time for the rest of the volume, at end time
        IBaseTrustedFiller swap2 = folio.createTrustedFill(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            cowswapFiller,
            bytes32(block.timestamp)
        );
        MockERC20(address(USDC)).burn(address(swap2), amt / 2);
        MockERC20(address(USDT)).mint(address(swap2), amt / 2);
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");

        // anyone should be able to close, even though it's ideal this happens in the cowswap post-hook
        swap2.closeFiller();
        assertEq(USDC.balanceOf(address(swap2)), 0, "wrong usdc balance");
        assertEq(USDT.balanceOf(address(swap2)), 0, "wrong usdt balance");

        // Folio should have balances
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong folio usdc balance");
        assertEq(USDT.balanceOf(address(folio)), amt * 5 + amt / 2, "wrong folio usdt balance");
    }

    function test_auctionIsValidSignature() public {
        // Sell USDC
        weights[0] = REMOVE;
        prices[0] = PRICE_POINT_6;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(HALF_PRICE_RANGE_6);
        bytes32 domainSeparator = 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;

        // deploy a MockEIP712 to the GPV2_SETTLEMENT address
        address mockEIP712 = address(new MockEIP712(domainSeparator));
        vm.etch(address(GPV2_SETTLEMENT), mockEIP712.code);

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        uint256[] memory auctionWeights = new uint256[](weights.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_DELAY);
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        (, , , , uint256 end) = folio.auctions(0);

        // isValidSignature should return true for the correct bid

        uint256 amt = D6_TOKEN_10K;
        IBaseTrustedFiller fill = folio.createTrustedFill(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            cowswapFiller,
            bytes32(0)
        );

        GPv2OrderLib.Data memory order = GPv2OrderLib.Data({
            sellToken: USDC,
            buyToken: USDT,
            receiver: address(fill),
            sellAmount: amt,
            buyAmount: amt * 10,
            validTo: uint32(end),
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2OrderLib.KIND_SELL,
            partiallyFillable: true,
            sellTokenBalance: GPv2OrderLib.BALANCE_ERC20,
            buyTokenBalance: GPv2OrderLib.BALANCE_ERC20
        });

        assertEq(
            fill.isValidSignature(GPv2OrderLib.hash(order, domainSeparator), abi.encode(order)),
            fill.isValidSignature.selector,
            "wrong isValidSignature"
        );

        // isValidSignature should revert for a slightly worse bid

        order.buyAmount -= 1;
        vm.expectRevert(abi.encodeWithSelector(CowSwapFiller.CowSwapFiller__OrderCheckFailed.selector, 100));
        fill.isValidSignature(GPv2OrderLib.hash(order, domainSeparator), abi.encode(order));
    }

    function test_trustedFillerNegativeCases() public {
        // createTrustedFill should not be executable until auction is open

        vm.expectRevert(); // Folio__NotRebalancing.selector ? or other?
        folio.createTrustedFill(0, IERC20(address(USDC)), IERC20(address(USDT)), cowswapFiller, bytes32(0));

        // Sell USDC
        weights[0] = REMOVE;
        prices[0] = PRICE_POINT_6;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(PRICE_POINT_6);

        // Start rebalance

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_DELAY);
        uint256[] memory auctionWeights = new uint256[](weights.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // now createTrustedFill should work

        IBaseTrustedFiller fill = folio.createTrustedFill(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            cowswapFiller,
            bytes32(block.timestamp)
        );
        assertEq(address(fill), address(uint160(uint256(vm.load(address(folio), bytes32(uint256(19)))))));

        // should mint, closing fill

        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);
        folio.mint(1e22, user1, 0);
        assertEq(address(0), address(uint160(uint256(vm.load(address(folio), bytes32(uint256(19)))))));

        // open another fill, should include fill balance in toAssets()

        fill = folio.createTrustedFill(
            0,
            IERC20(address(USDC)),
            IERC20(address(USDT)),
            cowswapFiller,
            bytes32(block.timestamp + 1)
        );
        assertNotEq(address(fill), address(0));
        assertEq(address(fill), address(uint160(uint256(vm.load(address(folio), bytes32(uint256(19)))))));

        // USDT should have been added to the basket beforehand

        uint256 redeemAmt = (1e22 * 3) / 20;
        (address[] memory basket, uint256[] memory amounts) = folio.toAssets(redeemAmt, Math.Rounding.Floor);
        assertEq(basket.length, 4);
        assertEq(basket[3], address(USDT));
        assertEq(amounts[3], 0);

        // amount of USDC in the basket should show Filler balance

        assertEq(basket[0], address(USDC));
        assertEq(amounts[0], redeemAmt / 1e12);

        // should redeem, closing fill

        folio.redeem((1e22 * 3) / 20, user1, basket, amounts);
        assertEq(address(0), address(uint160(uint256(vm.load(address(folio), bytes32(uint256(19)))))));
    }

    function test_auctionTinyPrices() public {
        // 1e-19 price

        // Sell MEME
        weights[2] = REMOVE;
        prices[2] = PRICE_POINT_27;

        // Buy USDC
        weights[0] = BUY;

        uint256 amt = D27_TOKEN_10K;
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + MAX_AUCTION_DELAY,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(IFolio.PriceControl.FULL, assets, weights, prices, limits, MAX_AUCTION_DELAY, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_DELAY);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // should have right bid at start, middle, and end of auction

        (, , , uint256 start, uint256 end) = folio.auctions(0);

        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(
            0,
            IERC20(address(MEME)),
            IERC20(address(USDC)),
            start,
            type(uint256).max
        );
        assertEq(sellAmount, amt, "wrong start sell amount");
        assertEq(buyAmount, (amt * 10) / 1e21, "wrong start buy amount"); // 100x

        (sellAmount, buyAmount, ) = folio.getBid(
            0,
            IERC20(address(MEME)),
            IERC20(address(USDC)),
            (start + end) / 2,
            type(uint256).max
        );
        assertEq(sellAmount, amt, "wrong mid sell amount");
        assertEq(buyAmount, amt / 1e21, "wrong mid buy amount"); // 10x

        (sellAmount, buyAmount, ) = folio.getBid(
            0,
            IERC20(address(MEME)),
            IERC20(address(USDC)),
            end,
            type(uint256).max
        );
        assertEq(sellAmount, amt, "wrong end sell amount");
        assertEq(buyAmount, (amt / 10) / 1e21, "wrong end buy amount"); // 1x
    }

    function test_auctionCloseAuctionByRebalanceManager() public {
        assets.push(address(USDT));
        weights.push(WEIGHTS_6);
        prices.push(FULL_PRICE_RANGE_6);

        uint256 amt = D6_TOKEN_10K;

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_LENGTH);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        vm.prank(user1);
        vm.expectRevert(IFolio.Folio__Unauthorized.selector);
        folio.closeAuction(1);

        (, , , , uint256 end) = folio.auctions(0);

        vm.startPrank(dao);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionClosed(1);
        folio.closeAuction(1);

        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionClosed(0);
        folio.closeAuction(0);

        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctionCloseAuctionByAuctionLauncher() public {
        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = REMOVE;

        // Buy DAI
        weights[1] = BUY;

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_LENGTH);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        vm.prank(user1);
        vm.expectRevert(IFolio.Folio__Unauthorized.selector);
        folio.closeAuction(1);

        (, , , , uint256 end) = folio.auctions(0);

        vm.startPrank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionClosed(1);
        folio.closeAuction(1);

        folio.closeAuction(0);

        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(DAI)), amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(DAI)), amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(DAI)), amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctionCloseAuctionByOwner() public {
        assets.push(address(USDT));
        weights.push(WEIGHTS_6);
        prices.push(FULL_PRICE_RANGE_6);

        uint256 amt = D6_TOKEN_10K;

        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_LENGTH);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        (, , , , uint256 end) = folio.auctions(0);

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionClosed(1);
        folio.closeAuction(1);

        folio.closeAuction(0);

        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_rebalanceAboveMaxTTL() public {
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidTTL.selector);
        folio.startRebalance(IFolio.PriceControl.FULL, assets, weights, prices, limits, MAX_AUCTION_DELAY, MAX_TTL + 1);
    }

    function test_auctionNotOpenableOutsideRebalance() public {
        // should not be openable until approved

        vm.startPrank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__NotRebalancing.selector);
        folio.openAuction(0, new address[](0), new uint256[](0), new IFolio.PriceRange[](0), ONE_BU, ONE_BU);

        vm.expectRevert(IFolio.Folio__InvalidRebalanceNonce.selector);
        folio.openAuction(1, new address[](0), new uint256[](0), new IFolio.PriceRange[](0), ONE_BU, ONE_BU);
    }

    function test_auctionUnrestrictedCallerCannotClobber() public {
        // Add USDT for auction setup
        assets.push(address(USDT));
        weights.push(WEIGHTS_6);
        prices.push(FULL_PRICE_RANGE_6);

        // Start rebalance
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }

        // Open auction
        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_LENGTH);
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // Attempt to open the same auction unrestricted
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__AuctionCannotBeOpenedWithoutRestriction.selector);
        folio.openAuctionUnrestricted(1);
    }

    function test_auctionNotLaunchableAfterTimeout() public {
        vm.prank(dao);
        // Start rebalance
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        // Warp time to just after the rebalance expires
        vm.warp(block.timestamp + MAX_TTL + 1);

        // Attempt to open an auction after the timeout
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__NotRebalancing.selector);

        // This call should revert because the rebalance period (availableUntil) has passed
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);
    }

    function test_auctionNotAvailableBeforeOpen() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        // auction should not be biddable before openAuction

        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(DAI)), amt, amt, false, bytes(""));
    }

    function test_auctionNotAvailableAfterEnd() public {
        uint256 amt = D6_TOKEN_1;
        vm.prank(dao);
        weights[0] = REMOVE;
        weights[1] = BUY;
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // auction should not be biddable after end

        (, , , , uint256 end) = folio.auctions(0);

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(DAI)), amt, amt, false, bytes(""));
    }

    function test_auctionBidRemovesTokenFromBasketAt0() public {
        // should not remove token from basket above 0

        uint256 amt = D6_TOKEN_10K;

        // Configure weights for selling USDC and buying DAI
        weights[0] = REMOVE;
        prices[0] = PRICE_POINT_6;
        weights[1] = BUY;
        prices[1] = PRICE_POINT_18;

        // Start rebalance
        vm.prank(dao);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        // Open auction
        vm.prank(auctionLauncher);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // Bid for most of the USDC, but not all
        vm.startPrank(user1);
        DAI.approve(address(folio), amt * 1e12);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(DAI)), amt - 1, (amt - 1) * 1e12, false, bytes(""));

        // Check basket still contains USDC
        (address[] memory tripleBasket, ) = folio.toAssets(1e18, Math.Rounding.Floor);
        assertEq(tripleBasket.length, 3);
        assertEq(tripleBasket[0], address(USDC));
        assertEq(tripleBasket[1], address(DAI));
        assertEq(tripleBasket[2], address(MEME));

        // Bid for the remaining USDC
        folio.bid(0, IERC20(address(USDC)), IERC20(address(DAI)), 1, 1e12, false, bytes(""));

        // Check USDC is removed from basket
        (address[] memory doubleBasket, ) = folio.toAssets(1e18, Math.Rounding.Floor);
        assertEq(doubleBasket.length, 2);
        assertEq(doubleBasket[0], address(MEME));
        assertEq(doubleBasket[1], address(DAI));
    }

    function test_auctionBidZeroAmount() public {
        vm.prank(dao);
        weights[1] = BUY;
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        vm.startPrank(user1);
        USDT.approve(address(folio), 0);
        vm.expectRevert(IFolio.Folio__InsufficientBuyAvailable.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(DAI)), 0, 0, false, bytes(""));
    }

    function test_auctionOnlyAuctionLauncherCanBypassDelay() public {
        vm.prank(dao);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        // cannot permissionlessly open auction during restricted perieod

        vm.expectRevert(IFolio.Folio__AuctionCannotBeOpenedWithoutRestriction.selector);
        folio.openAuctionUnrestricted(1);

        // but should be possible after auction launcher window
        (, , , uint256 restrictedUntil, , ) = folio.rebalance();
        vm.warp(restrictedUntil);
        folio.openAuctionUnrestricted(1);

        // and AUCTION_LAUNCHER can clobber
        vm.prank(auctionLauncher);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);
    }

    function test_auctionDishonestCallback() public {
        uint256 amt = D6_TOKEN_1;

        // Sell USDC
        weights[0] = REMOVE;
        prices[0] = PRICE_POINT_6;

        // Buy DAI
        weights[1] = BUY;
        prices[1] = PRICE_POINT_18;

        vm.prank(dao);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU); // 1x

        // dishonest callback that returns fewer tokens than expected

        MockBidder mockBidder = new MockBidder(false);
        DAI.transfer(address(mockBidder), amt * 1e12 - 1);
        vm.prank(address(mockBidder));
        vm.expectRevert(abi.encodeWithSelector(IFolio.Folio__InsufficientBid.selector));
        folio.bid(0, IERC20(address(USDC)), IERC20(address(DAI)), amt, amt * 1e12, true, bytes(""));
    }

    function test_parallelAuctionsOnBuyToken() public {
        // launch two auction in parallel to sell ALL USDC/DAI

        // Sell USDC + DAI
        weights[0] = REMOVE;
        weights[1] = REMOVE;

        // Add USDT
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(PRICE_POINT_6);

        uint256 amt1 = USDC.balanceOf(address(folio));
        uint256 amt2 = DAI.balanceOf(address(folio));
        vm.prank(dao);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // bid in first pair auction for half volume at start

        vm.startPrank(user1);
        USDT.approve(address(folio), amt1 * 100);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt1, amt1 * 100, false, bytes(""));

        // bid in second pair for rest of volume at start

        vm.startPrank(user2);
        USDT.approve(address(folio), amt1 * 100);
        folio.bid(0, IERC20(address(DAI)), IERC20(address(USDT)), amt2, amt1 * 100, false, bytes(""));

        // should be empty

        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        assertEq(DAI.balanceOf(address(folio)), 0, "wrong dai balance");
    }

    function test_parallelAuctionsOnSellToken() public {
        // Sell USDC
        weights[0] = REMOVE;

        // Buy DAI and USDT
        weights[1] = BUY;
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(PRICE_POINT_6);

        // Start rebalance
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        uint256 amt1 = USDC.balanceOf(address(folio));

        // Open auction
        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_LENGTH);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // bid for half of sell volume for DAI at start

        vm.startPrank(user1);
        DAI.approve(address(folio), (amt1 * 1e12 * 100) / 2);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(DAI)), amt1 / 2, (amt1 * 1e12 * 100) / 2, false, bytes(""));

        // bid in second pair for rest of volume at start

        vm.startPrank(user2);
        USDT.approve(address(folio), (amt1 * 100) / 2);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt1 / 2, (amt1 * 100) / 2, false, bytes(""));

        // should be empty

        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
    }

    function test_auctionPriceRange() public {
        // Sell USDC
        weights[0] = REMOVE;

        // Add USDT
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        vm.prank(dao);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        for (uint256 i = MAX_TOKEN_PRICE; i > 0; i /= 10) {
            uint256 index = folio.nextAuctionId();

            prices[3] = IFolio.PriceRange({ low: (i + MAX_TOKEN_PRICE_RANGE - 1) / MAX_TOKEN_PRICE_RANGE, high: i });

            // should not revert at top or bottom end
            vm.prank(auctionLauncher);
            uint256[] memory auctionWeights = new uint256[](assets.length);
            for (uint256 j = 0; j < assets.length; j++) {
                auctionWeights[j] = weights[j].spot;
            }
            folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);
            (, , , uint256 start, uint256 end) = folio.auctions(index);

            // should not revert
            folio.getBid(index, IERC20(address(USDC)), IERC20(address(USDT)), start, type(uint256).max);
            folio.getBid(index, IERC20(address(USDC)), IERC20(address(USDT)), end, type(uint256).max);
        }
    }

    function test_upgrade() public {
        // Deploy and register new factory with version 10.0.0
        FolioDeployer newDeployerV2 = new FolioDeployerV2(
            address(daoFeeRegistry),
            address(versionRegistry),
            address(trustedFillerRegistry),
            governanceDeployer
        );
        versionRegistry.registerVersion(newDeployerV2);

        // Check implementation for new version
        bytes32 newVersion = keccak256("10.0.0");
        address impl = versionRegistry.getImplementationForVersion(newVersion);
        assertEq(impl, newDeployerV2.folioImplementation());

        // Check current version
        assertEq(folio.version(), VERSION);

        // upgrade to V2 with owner
        vm.prank(owner);
        proxyAdmin.upgradeToVersion(address(folio), keccak256("10.0.0"), "");
        assertEq(folio.version(), "10.0.0");
    }

    function test_cannotUpgradeToVersionNotInRegistry() public {
        // Check current version
        assertEq(folio.version(), VERSION);

        // Attempt to upgrade to V2 (not registered)
        vm.prank(owner);
        vm.expectRevert();
        proxyAdmin.upgradeToVersion(address(folio), keccak256("10.0.0"), "");

        // still on old version
        assertEq(folio.version(), VERSION);
    }

    function test_cannotUpgradeToDeprecatedVersion() public {
        // Deploy and register new factory with version 10.0.0
        FolioDeployer newDeployerV2 = new FolioDeployerV2(
            address(daoFeeRegistry),
            address(versionRegistry),
            address(trustedFillerRegistry),
            governanceDeployer
        );
        versionRegistry.registerVersion(newDeployerV2);

        // deprecate version
        versionRegistry.deprecateVersion(keccak256("10.0.0"));

        // Check current version
        assertEq(folio.version(), VERSION);

        // Attempt to upgrade to V2 (deprecated)
        vm.prank(owner);
        vm.expectRevert(FolioProxyAdmin.VersionDeprecated.selector);
        proxyAdmin.upgradeToVersion(address(folio), keccak256("10.0.0"), "");

        // still on old version
        assertEq(folio.version(), VERSION);
    }

    function test_cannotUpgradeIfNotOwnerOfProxyAdmin() public {
        // Deploy and register new factory with version 10.0.0
        FolioDeployer newDeployerV2 = new FolioDeployerV2(
            address(daoFeeRegistry),
            address(versionRegistry),
            address(trustedFillerRegistry),
            governanceDeployer
        );
        versionRegistry.registerVersion(newDeployerV2);

        // Attempt to upgrade to V2 with random user
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        proxyAdmin.upgradeToVersion(address(folio), keccak256("10.0.0"), "");
    }

    function test_cannotCallAnyOtherFunctionFromProxyAdmin() public {
        // Attempt to call other functions in folio from ProxyAdmin
        vm.prank(address(proxyAdmin));
        vm.expectRevert(abi.encodeWithSelector(FolioProxy.ProxyDeniedAdminAccess.selector));
        folio.version();
    }

    function test_cannotUpgradeFolioDirectly() public {
        // Deploy and register new factory with version 10.0.0
        FolioDeployer newDeployerV2 = new FolioDeployerV2(
            address(daoFeeRegistry),
            address(versionRegistry),
            address(trustedFillerRegistry),
            governanceDeployer
        );
        versionRegistry.registerVersion(newDeployerV2);

        // Get implementation for new version
        bytes32 newVersion = keccak256("10.0.0");
        address impl = versionRegistry.getImplementationForVersion(newVersion);
        assertEq(impl, newDeployerV2.folioImplementation());

        // Attempt to upgrade to V2 directly on the proxy
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(folio)).upgradeToAndCall(impl, "");
    }

    function test_auctionCannotBidIfExceedsSlippage() public {
        // Test bid reverts due to slippage if maxBuyAmount is too low.
        uint256 amt = D6_TOKEN_1;

        // Sell USDC
        weights[0] = REMOVE;
        prices[0] = PRICE_POINT_6;

        // Buy USDT
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(PRICE_POINT_6);

        // Start rebalance
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        // Open auction
        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_LENGTH);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 j = 0; j < assets.length; j++) {
            auctionWeights[j] = weights[j].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // Attempt bid with extremely low maxBuyAmount, causing slippage revert
        vm.startPrank(user1);
        USDT.approve(address(folio), amt);
        vm.expectRevert(IFolio.Folio__SlippageExceeded.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), amt, 1, false, bytes(""));
        vm.stopPrank();
    }
    function test_auctionCannotBidForMoreThanAvailable() public {
        // Test bid reverts if sellAmount exceeds Folio's token balance.

        // Setup: Add USDT to auction, get available USDC.
        assets.push(address(USDT));
        weights.push(WEIGHTS_6);
        prices.push(FULL_PRICE_RANGE_6);

        uint256 usdcAvailable = USDC.balanceOf(address(folio));

        // Start rebalance
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        // Open auction for USDC -> USDT
        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, ONE_BU, ONE_BU, block.timestamp, block.timestamp + MAX_AUCTION_LENGTH);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 j = 0; j < assets.length; j++) {
            auctionWeights[j] = weights[j].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        // Attempt to bid for more USDC than is available in the folio.
        vm.startPrank(user1);
        uint256 excessBidAmount = usdcAvailable + 1;
        uint256 requiredUSDT = excessBidAmount;
        USDT.approve(address(folio), requiredUSDT);

        vm.expectRevert(IFolio.Folio__InsufficientSellAvailable.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), excessBidAmount, requiredUSDT, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctionCannotOpenAuctionWithInvalidTokens() public {
        // Start rebalance first (nonce 1)
        vm.prank(dao);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.startPrank(auctionLauncher);

        // Prepare valid weight/price arrays (length 2 for simplicity)
        uint256[] memory validWeights = new uint256[](2);
        validWeights[0] = weights[0].spot;
        validWeights[1] = weights[1].spot;

        IFolio.PriceRange[] memory validPrices = new IFolio.PriceRange[](2);
        validPrices[0] = prices[0];
        validPrices[1] = prices[1];

        // --- Case 1: Sell token is zero address ---
        address[] memory invalidTokens1 = new address[](2);
        invalidTokens1[0] = address(0); // Invalid sell token
        invalidTokens1[1] = address(USDC);
        // This should fail because address(0) is not part of the rebalance details.
        vm.expectRevert(IFolio.Folio__TokenNotInRebalance.selector);
        folio.openAuction(1, invalidTokens1, validWeights, validPrices, ONE_BU, ONE_BU);

        // --- Case 2: Buy token is zero address ---
        address[] memory invalidTokens2 = new address[](2);
        invalidTokens2[0] = address(USDC);
        invalidTokens2[1] = address(0); // Invalid buy token
        vm.expectRevert(IFolio.Folio__TokenNotInRebalance.selector);
        folio.openAuction(1, invalidTokens2, validWeights, validPrices, ONE_BU, ONE_BU);

        // --- Case 3: Sell token is the Folio address ---
        address[] memory invalidTokens3 = new address[](2);
        invalidTokens3[0] = address(folio); // Invalid sell token
        invalidTokens3[1] = address(USDC);
        vm.expectRevert(IFolio.Folio__TokenNotInRebalance.selector);
        folio.openAuction(1, invalidTokens3, validWeights, validPrices, ONE_BU, ONE_BU);

        // --- Case 4: Buy token is the Folio address ---
        address[] memory invalidTokens4 = new address[](2);
        invalidTokens4[0] = address(USDC);
        invalidTokens4[1] = address(folio); // Invalid buy token
        vm.expectRevert(IFolio.Folio__TokenNotInRebalance.selector);
        folio.openAuction(1, invalidTokens4, validWeights, validPrices, ONE_BU, ONE_BU);
        vm.stopPrank();
    }

    function test_auctionCannotStartRebalanceOnDuplicateTokens() public {
        assets[1] = assets[0];

        vm.startPrank(dao);
        vm.expectRevert(IFolio.Folio__DuplicateAsset.selector);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );
    }

    function test_auctionCannotStartRebalanceWithInvalidSellLimit() public {
        // This test checks general invalid RebalanceLimits, not just sell limits.
        vm.startPrank(dao);

        // --- Case 1: limits.low == 0 ---
        IFolio.RebalanceLimits memory invalidLimits1 = IFolio.RebalanceLimits({
            low: 0, // Invalid: low must be > 0
            spot: 1,
            high: MAX_LIMIT
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            invalidLimits1,
            MAX_AUCTION_DELAY,
            MAX_TTL
        );

        // --- Case 2: limits.low > limits.spot ---
        IFolio.RebalanceLimits memory invalidLimits2 = IFolio.RebalanceLimits({
            low: 2,
            spot: 1, // Invalid: spot < low
            high: MAX_LIMIT
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            invalidLimits2,
            MAX_AUCTION_DELAY,
            MAX_TTL
        );

        // --- Case 3: limits.spot > limits.high ---
        IFolio.RebalanceLimits memory invalidLimits3 = IFolio.RebalanceLimits({
            low: 1,
            spot: MAX_LIMIT,
            high: MAX_LIMIT - 1 // Invalid: high < spot
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            invalidLimits3,
            MAX_AUCTION_DELAY,
            MAX_TTL
        );

        // --- Case 4: limits.high > MAX_LIMIT ---
        IFolio.RebalanceLimits memory invalidLimits4 = IFolio.RebalanceLimits({
            low: 1,
            spot: 1,
            high: MAX_LIMIT + 1 // Invalid: high > MAX_LIMIT
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            invalidLimits4,
            MAX_AUCTION_DELAY,
            MAX_TTL
        );

        vm.stopPrank();
    }

    function test_auctionCannotStartRebalanceWithInvalidBuyLimit() public {
        // This test checks general invalid RebalanceLimits, similar to the previous test.
        // The name is kept for historical reasons, but it tests the same constraints.
        vm.startPrank(dao);

        // --- Case 1: limits.low > limits.high ---
        IFolio.RebalanceLimits memory invalidLimits1 = IFolio.RebalanceLimits({
            low: MAX_LIMIT, // Low is high
            spot: MAX_LIMIT,
            high: MAX_LIMIT - 1 // High is lower than low
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            invalidLimits1,
            MAX_AUCTION_DELAY,
            MAX_TTL
        );

        // --- Case 2: limits.high > MAX_LIMIT (Redundant, but kept for clarity) ---
        IFolio.RebalanceLimits memory invalidLimits2 = IFolio.RebalanceLimits({
            low: 1,
            spot: 1,
            high: MAX_LIMIT + 1 // High exceeds maximum
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            invalidLimits2,
            MAX_AUCTION_DELAY,
            MAX_TTL
        );

        // --- Case 3: limits.spot < limits.low (Redundant, but kept for clarity) ---
        IFolio.RebalanceLimits memory invalidLimits3 = IFolio.RebalanceLimits({
            low: 10, // Low is 10
            spot: 5, // Spot is less than low
            high: MAX_LIMIT
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            invalidLimits3,
            MAX_AUCTION_DELAY,
            MAX_TTL
        );

        vm.stopPrank();
    }

    function test_auctionCannotOpenAuctionWithInvalidPrices() public {
        // Start rebalance
        vm.prank(dao);
        vm.expectEmit(true, true, true, false);
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL
        );
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.startPrank(auctionLauncher);

        // Prepare valid base parameters
        address[] memory auctionAddresses = new address[](2);
        auctionAddresses[0] = address(USDC);
        auctionAddresses[1] = address(DAI);

        uint256[] memory auctionWeights = new uint256[](2);
        auctionWeights[0] = weights[0].spot;
        auctionWeights[1] = weights[1].spot;

        IFolio.PriceRange[] memory invalidPrices = new IFolio.PriceRange[](2);
        invalidPrices[1] = prices[1]; // Keep DAI price valid for these tests

        // --- Case 1: Low price is zero ---
        invalidPrices[0] = IFolio.PriceRange({ low: 0, high: 1e16 }); // Invalid low = 0
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, auctionAddresses, auctionWeights, invalidPrices, ONE_BU, ONE_BU);

        // --- Case 2: Low price greater than high price ---
        invalidPrices[0] = IFolio.PriceRange({ low: 1e16, high: 1e15 }); // Invalid low > high
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, auctionAddresses, auctionWeights, invalidPrices, ONE_BU, ONE_BU);

        // --- Case 3: High price exceeds MAX_TOKEN_PRICE ---
        invalidPrices[0] = IFolio.PriceRange({ low: 1e16, high: MAX_TOKEN_PRICE + 1 }); // Invalid high > max
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, auctionAddresses, auctionWeights, invalidPrices, ONE_BU, ONE_BU);

        // --- Case 4: High price exceeds range limit relative to low price ---
        uint256 lowPrice = 1e15;
        invalidPrices[0] = IFolio.PriceRange({ low: lowPrice, high: MAX_TOKEN_PRICE_RANGE * lowPrice + 1 }); // Invalid high > range * low
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, auctionAddresses, auctionWeights, invalidPrices, ONE_BU, ONE_BU);
        vm.stopPrank();
    }

    function test_auctionCannotRebalanceIfFolioDeprecated() public {
        vm.prank(owner);
        folio.deprecateFolio();

        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__FolioDeprecated.selector);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);
    }

    function test_auctionCannotBidIfFolioDeprecated() public {
        vm.prank(dao);
        weights[1] = BUY;
        folio.startRebalance(
            IFolio.PriceControl.FULL,
            assets,
            weights,
            prices,
            limits,
            AUCTION_LAUNCHER_WINDOW,
            MAX_TTL
        );

        vm.prank(auctionLauncher);
        uint256[] memory auctionWeights = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            auctionWeights[i] = weights[i].spot;
        }
        folio.openAuction(1, assets, auctionWeights, prices, ONE_BU, ONE_BU);

        vm.prank(owner);
        folio.deprecateFolio();

        vm.expectRevert(IFolio.Folio__FolioDeprecated.selector);
        folio.bid(0, IERC20(address(USDC)), IERC20(address(USDT)), 1e27, 1e27, false, bytes(""));
        assertEq(folio.isDeprecated(), true, "wrong deprecated status");
    }

    function test_redeemMaxSlippage() public {
        assertEq(folio.balanceOf(user1), 0, "wrong starting user1 balance");
        vm.startPrank(user1);
        USDC.approve(address(folio), type(uint256).max);
        DAI.approve(address(folio), type(uint256).max);
        MEME.approve(address(folio), type(uint256).max);
        folio.mint(1e22, user1, 0);
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

    function test_deprecateFolio() public {
        assertFalse(folio.isDeprecated(), "wrong deprecated status");

        vm.prank(owner);
        folio.deprecateFolio();

        assertTrue(folio.isDeprecated(), "wrong deprecated status");
    }

    function test_cannotDeprecateFolioIfNotOwner() public {
        assertFalse(folio.isDeprecated(), "wrong deprecated status");

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.deprecateFolio();
        vm.stopPrank();
        assertFalse(folio.isDeprecated(), "wrong deprecated status");
    }

    function test_cannotAddZeroAddressToBasket() public {
        vm.startPrank(owner);
        vm.expectRevert(IFolio.Folio__InvalidAsset.selector);
        folio.addToBasket(IERC20(address(0)));
    }

    function test_cannotSendFolioToFolio() public {
        // only the activeTrustedFill can send Folio to Folio; tested higher up

        vm.startPrank(owner);
        vm.expectRevert(IFolio.Folio__InvalidTransferToSelf.selector);
        folio.transfer(address(folio), 1);
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
