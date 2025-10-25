// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IBaseTrustedFiller } from "@reserve-protocol/trusted-fillers/contracts/interfaces/IBaseTrustedFiller.sol";
import { GPv2OrderLib } from "@reserve-protocol/trusted-fillers/contracts/fillers/cowswap/GPv2OrderLib.sol";
import { GPV2_SETTLEMENT } from "@reserve-protocol/trusted-fillers/contracts/fillers/cowswap/Constants.sol";
import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio } from "contracts/Folio.sol";
import { AUCTION_WARMUP, D27, MIN_AUCTION_LENGTH, MAX_AUCTION_LENGTH, MAX_MINT_FEE, MAX_TTL, MAX_FEE_RECIPIENTS, MAX_TOKEN_PRICE, MAX_TOKEN_PRICE_RANGE, MAX_TVL_FEE, MAX_LIMIT, MAX_WEIGHT } from "@utils/Constants.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FolioProxyAdmin, FolioProxy } from "contracts/folio/FolioProxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { FolioDeployerV2 } from "test/utils/upgrades/FolioDeployerV2.sol";
import { MockEIP712 } from "test/utils/MockEIP712.sol";
import { MockDonatingBidder } from "test/utils/MockDonatingBidder.sol";
import { MockBidder } from "utils/MockBidder.sol";
import "./base/BaseTest.sol";

contract FolioTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;
    uint256 internal constant MAX_TVL_FEE_PER_SECOND = 3340960028; // D18{1/s} 10% annually, per second
    uint256 internal constant AUCTION_LAUNCHER_WINDOW = MAX_TTL / 2;
    uint256 internal constant AUCTION_LENGTH = 1800; // {s} 30 min

    IFolio.WeightRange internal SELL = IFolio.WeightRange({ low: 0, spot: 0, high: 0 }); // sell as much as possible
    IFolio.WeightRange internal BUY = IFolio.WeightRange({ low: MAX_WEIGHT, spot: MAX_WEIGHT, high: MAX_WEIGHT }); // buy as much as possible
    IFolio.WeightRange internal BUY_FULL_RANGE = IFolio.WeightRange({ low: 0, spot: MAX_WEIGHT, high: MAX_WEIGHT }); // default BUY, but can remove

    IFolio.WeightRange internal WEIGHTS_6 = IFolio.WeightRange({ low: 1e15, spot: 1e15, high: 1e15 }); // D27{tok/BU} 1:1 with BUs
    IFolio.WeightRange internal WEIGHTS_18 = IFolio.WeightRange({ low: 1e27, spot: 1e27, high: 1e27 }); // D27{tok/BU} 1:1 with BUs
    IFolio.WeightRange internal WEIGHTS_27 = IFolio.WeightRange({ low: 1e36, spot: 1e36, high: 1e36 }); // D27{tok/BU} 1:1 with BUs

    IFolio.PriceRange internal FULL_PRICE_RANGE_6 = IFolio.PriceRange({ low: 1e20, high: 1e22 }); // D27{UoA/tok} [$0.1, $10] $1 token
    IFolio.PriceRange internal FULL_PRICE_RANGE_18 = IFolio.PriceRange({ low: 1e8, high: 1e10 }); // D27{UoA/tok} [$0.1, $10] $1 token
    IFolio.PriceRange internal FULL_PRICE_RANGE_27 = IFolio.PriceRange({ low: 1, high: 100 }); // D27{UoA/tok} [$1, $100] $10 token

    IFolio.PriceRange internal PRICE_POINT_6 = IFolio.PriceRange({ low: 1e21, high: 1e21 }); // D27{UoA/tok} $1
    IFolio.PriceRange internal PRICE_POINT_18 = IFolio.PriceRange({ low: 1e9, high: 1e9 }); // D27{UoA/tok} $1
    IFolio.PriceRange internal PRICE_POINT_27 = IFolio.PriceRange({ low: 10, high: 10 }); // D27{UoA/tok} $10

    uint256 internal constant ONE_BU = 1e18;
    IFolio.RebalanceLimits internal TRACKING_LIMITS = IFolio.RebalanceLimits({ low: 1, spot: ONE_BU, high: MAX_LIMIT });
    IFolio.RebalanceLimits internal NATIVE_LIMITS = IFolio.RebalanceLimits({ low: ONE_BU, spot: ONE_BU, high: ONE_BU });

    address[] assets;
    IFolio.WeightRange[] weights;
    IFolio.PriceRange[] prices;
    IFolio.RebalanceLimits limits;

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
        limits = TRACKING_LIMITS;

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
            AUCTION_LENGTH,
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
            auctionLength: AUCTION_LENGTH,
            feeRecipients: recipients,
            tvlFee: MAX_TVL_FEE,
            mintFee: 0,
            mandate: "mandate"
        });

        IFolio.FolioRegistryIndex memory registryIndex = IFolio.FolioRegistryIndex({
            daoFeeRegistry: address(daoFeeRegistry),
            trustedFillerRegistry: address(trustedFillerRegistry)
        });

        IFolio.FolioFlags memory folioFlags = IFolio.FolioFlags({
            trustedFillerEnabled: true,
            rebalanceControl: IFolio.RebalanceControl({ weightControl: false, priceControl: IFolio.PriceControl.NONE }),
            bidsEnabled: true
        });

        // Attempt to initialize
        vm.expectRevert(IFolio.Folio__InvalidAsset.selector);
        newFolio.initialize(basicDetails, additionalDetails, registryIndex, folioFlags, address(this));
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
            AUCTION_LENGTH,
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
        assertEq(folio.auctionLength(), AUCTION_LENGTH, "wrong auction length");

        vm.expectEmit(true, true, false, true);
        emit IFolio.AuctionLengthSet(MAX_AUCTION_LENGTH);
        folio.setAuctionLength(MAX_AUCTION_LENGTH);
        assertEq(folio.auctionLength(), MAX_AUCTION_LENGTH, "wrong auction length");

        vm.expectEmit(true, true, false, true);
        emit IFolio.AuctionLengthSet(MIN_AUCTION_LENGTH);
        folio.setAuctionLength(MIN_AUCTION_LENGTH);
        assertEq(folio.auctionLength(), MIN_AUCTION_LENGTH, "wrong auction length");

        vm.expectRevert(IFolio.Folio__InvalidAuctionLength.selector);
        folio.setAuctionLength(MIN_AUCTION_LENGTH - 1);

        vm.expectRevert(IFolio.Folio__InvalidAuctionLength.selector);
        folio.setAuctionLength(MAX_AUCTION_LENGTH + 1);
    }

    function test_setMandate() public {
        assertEq(folio.mandate(), "mandate", "wrong mandate");
        string memory newMandate = "new mandate";

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IFolio.MandateSet(newMandate);
        folio.setMandate(newMandate);
        assertEq(folio.mandate(), newMandate, "wrong mandate");

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

    function test_setName() public {
        assertEq(folio.name(), "Test Folio", "wrong name");
        string memory newName = "Test Folio NewName";

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IFolio.NameSet(newName);
        folio.setName(newName);
        assertEq(folio.name(), newName, "wrong name");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                dao,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(dao);
        folio.setName(newName);
    }

    function test_setTrustedFillerRegistry() public {
        vm.startPrank(owner);

        // First attempt to set new registry should fail since one is already set
        address newRegistry = address(0x1234);
        bool enabled = true;
        vm.expectRevert(IFolio.Folio__TrustedFillerRegistryAlreadySet.selector);
        folio.setTrustedFillerRegistry(newRegistry, enabled);

        // Get current registry
        address currentRegistry = address(folio.trustedFillerRegistry());

        // Should be able to disable the current registry
        vm.expectEmit(true, true, false, true);
        emit IFolio.TrustedFillerRegistrySet(currentRegistry, false);
        folio.setTrustedFillerRegistry(currentRegistry, false);
        assertEq(address(folio.trustedFillerRegistry()), currentRegistry, "wrong trusted filler registry");

        // Should be able to re-enable the current registry
        vm.expectEmit(true, true, false, true);
        emit IFolio.TrustedFillerRegistrySet(currentRegistry, true);
        folio.setTrustedFillerRegistry(currentRegistry, true);
        assertEq(address(folio.trustedFillerRegistry()), currentRegistry, "wrong trusted filler registry");

        vm.stopPrank();

        // Try to set registry with unauthorized account (user1)
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.setTrustedFillerRegistry(currentRegistry, false);
        vm.stopPrank();
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

        // make atomic swappable
        vm.prank(owner);
        folio.setRebalanceControl(
            IFolio.RebalanceControl({ weightControl: false, priceControl: IFolio.PriceControl.ATOMIC_SWAP })
        );

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.ATOMIC_SWAP,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // use atomic swap prices
        prices[0] = PRICE_POINT_6;
        prices[1] = PRICE_POINT_18;
        prices[2] = PRICE_POINT_27;
        prices[3] = PRICE_POINT_6;

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, weights, prices, NATIVE_LIMITS, block.timestamp, block.timestamp);

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        // bid for half volume, leaving rest unused

        vm.startPrank(user1);
        USDT.approve(address(folio), amt);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt / 2);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, amt / 2, false, bytes(""));

        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong start sell amount");
        assertEq(buyAmount, amt / 2, "wrong start buy amount");

        USDT.approve(address(folio), amt);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt / 2);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, amt / 2, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();

        // 2nd half of volume should not be fillable at next timestamp because auction over

        vm.warp(block.timestamp + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.getBid(0, USDC, IERC20(address(USDT)), amt);
    }

    function test_atomicBidWithCallback() public {
        // bid in two chunks, one at start time and one at end time

        // make atomic swappable
        vm.prank(owner);
        folio.setRebalanceControl(
            IFolio.RebalanceControl({ weightControl: false, priceControl: IFolio.PriceControl.ATOMIC_SWAP })
        );

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.ATOMIC_SWAP,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // use atomic swap prices
        prices[0] = PRICE_POINT_6;
        prices[1] = PRICE_POINT_18;
        prices[2] = PRICE_POINT_27;
        prices[3] = PRICE_POINT_6;

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, false);
        emit IFolio.AuctionOpened(1, 0, assets, weights, prices, NATIVE_LIMITS, block.timestamp, block.timestamp);

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        // bid for half volume, leaving rest unused

        MockBidder mockBidder = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder), amt / 2);
        vm.prank(address(mockBidder));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt / 2);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong start sell amount");
        assertEq(buyAmount, amt / 2, "wrong start buy amount");

        // donating bidder donates SELL token back afterwards
        uint256 refund = amt / 2 / 2;
        MockDonatingBidder donatingBidder = new MockDonatingBidder(true, USDC, refund);
        USDC.transfer(address(donatingBidder), refund);

        vm.prank(user1);
        USDT.transfer(address(donatingBidder), amt / 2);

        vm.prank(address(donatingBidder));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2 - refund, amt / 2);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, amt / 2, true, bytes(""));
        assertEq(USDT.balanceOf(address(donatingBidder)), 0, "wrong mock bidder2 balance");
        assertEq(USDC.balanceOf(address(folio)), refund, "wrong usdc balance");
        vm.stopPrank();

        // make sure USDC is still in basket
        (address[] memory basketTokens, ) = folio.totalAssets();
        bool found = false;
        for (uint256 i; i < basketTokens.length; i++) {
            if (basketTokens[i] == address(USDC)) {
                found = true;
                break;
            }
        }
        assertEq(found, true, "removed sell token accidentally");

        // 2nd half of volume should not be fillable at next timestamp because auction over

        vm.warp(block.timestamp + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.getBid(0, USDC, IERC20(address(USDT)), amt);
    }

    function test_maxAuctionSize() public {
        // Test max auction size within a single auction and across different auctions
        // Also tests cross-decimal trading: USDC (6 decimals) -> DAI (18 decimals)

        // Phase 1: Setup - enable atomic swaps
        vm.prank(owner);
        folio.setRebalanceControl(
            IFolio.RebalanceControl({ weightControl: false, priceControl: IFolio.PriceControl.ATOMIC_SWAP })
        );

        uint256 maxAuctionSize = 6000e6; // 6000 USDC with 6 decimals

        // Sell USDC with limited max auction size
        weights[0] = SELL;

        // Buy DAI (18 decimals) - testing cross-decimal trading
        weights[1] = BUY;

        // Phase 2: Start first rebalance with maxAuctionSize limit
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], maxAuctionSize, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // use atomic swap prices
        prices[0] = PRICE_POINT_6;
        prices[1] = PRICE_POINT_18;
        prices[2] = PRICE_POINT_27;

        // Auction 1: Test max auction size with multiple bids
        vm.prank(auctionLauncher);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        // First bid: 2500 USDC for 2500 DAI
        uint256 amt1 = 2500e6; // sell amount in USDC (6 decimals)
        vm.startPrank(user1);
        DAI.approve(address(folio), 2500e18); // buy amount in DAI (18 decimals)
        folio.bid(0, USDC, DAI, amt1, 2500e18, false, bytes(""));

        // Second bid: 2500 USDC more (total 5000)
        uint256 amt2 = 2500e6; // sell amount in USDC (6 decimals)
        DAI.approve(address(folio), 2500e18); // buy amount in DAI (18 decimals)
        folio.bid(0, USDC, DAI, amt2, 2500e18, false, bytes(""));

        // Third bid attempt: Try to get 5000 USDC, should only get remaining 1000
        uint256 requestedAmt = 5000e6;
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, USDC, DAI, requestedAmt);
        assertEq(sellAmount, 1000e6, "should only have 1000 USDC remaining in auction");
        assertEq(buyAmount, 1000e18, "should only need 1000 DAI (18 decimals)");

        // Bid the remaining 1000 USDC
        DAI.approve(address(folio), 1000e18);
        folio.bid(0, USDC, DAI, 1000e6, 1000e18, false, bytes(""));

        // Verify no more USDC can be sold in this auction (max auction size reached)
        (uint256 sellAmountRemaining, , ) = folio.getBid(0, USDC, DAI, 1000e6);
        assertEq(sellAmountRemaining, 0, "no USDC should remain after hitting max auction size");
        vm.stopPrank();

        // Auction 2: Verify max auction size resets for new auction within same rebalance
        vm.prank(auctionLauncher);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        // Should be able to bid up to maxAuctionSize again in new auction
        (sellAmountRemaining, , ) = folio.getBid(1, USDC, DAI, 1000e6);
        assertGt(sellAmountRemaining, 0, "max auction size should reset for new auction");
    }

    function test_auctionBidWithoutCallback() public {
        // bid in two chunks, one at start time and one at end time

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // bid once at start time

        vm.startPrank(user1);
        USDT.approve(address(folio), (amt / 2) * 100);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, (amt / 2) * 100);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, (amt / 2) * 100, false, bytes(""));

        (, uint256 start, uint256 end) = folio.auctions(0);

        vm.warp(start);
        vm.startSnapshotGas("getBid()");
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        vm.stopSnapshotGas();
        assertEq(sellAmount, amt / 2, "wrong start sell amount");
        assertEq(buyAmount, (amt / 2) * 100, "wrong start buy amount");

        vm.warp((start + end) / 2);
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong mid sell amount");
        assertEq(buyAmount, (amt / 2) + 1, "wrong mid buy amount");

        vm.warp(end);
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong end sell amount");
        assertEq(buyAmount, (amt / 2) / 100, "wrong end buy amount");

        // bid a 2nd time for the rest of the volume, at end time
        USDT.approve(address(folio), (amt / 2) / 100);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, (amt / 2) / 100);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, (amt / 2) / 100, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionBidWithCallback() public {
        // bid in two chunks, one at start time and one at end time

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // bid once at start time (10x)

        MockBidder mockBidder = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder), amt * 50);
        vm.prank(address(mockBidder));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt * 50);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, amt * 50, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        // check prices
        (, uint256 start, uint256 end) = folio.auctions(0);

        vm.warp(start);
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong start sell amount");
        assertEq(buyAmount, amt * 50, "wrong start buy amount"); // 100x

        vm.warp((start + end) / 2);
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong mid sell amount");
        assertEq(buyAmount, amt / 2 + 1, "wrong mid buy amount"); // ~1x

        vm.warp(end);
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong end sell amount");
        assertEq(buyAmount, amt / 200, "wrong end buy amount"); // 1/100x

        // bid a 2nd time for the rest of the volume, at end time

        MockBidder mockBidder2 = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder2), amt / 200);
        vm.prank(address(mockBidder2));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, amt / 200);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, amt / 200, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder2)), 0, "wrong mock bidder2 balance");
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_auctionBidsDisabled() public {
        // check protected
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.setBidsEnabled(false);

        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        // start rebalance while bidsEnabled
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // disable bids after starting rebalance
        vm.prank(owner);
        folio.setBidsEnabled(false);

        bool bidsEnabledView = folio.bidsEnabled();
        assertEq(bidsEnabledView, false, "direct view should be false");
        (, , , , , bool bidsEnabled) = folio.getRebalance();
        assertEq(bidsEnabled, true, "bids enabled should still be true");

        // open auction
        vm.prank(auctionLauncher);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // bid should work
        USDT.approve(address(folio), D6_TOKEN_10K * 200);
        folio.bid(0, USDC, IERC20(address(USDT)), D6_TOKEN_10K, D6_TOKEN_10K * 100, false, bytes(""));

        // start another rebalance and auction
        tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // now bids should be disabled
        (, , , , , bidsEnabled) = folio.getRebalance();
        assertEq(bidsEnabled, false, "bids enabled should be false");

        vm.prank(auctionLauncher);
        folio.openAuction(2, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // bid should revert now
        vm.expectRevert(IFolio.Folio__PermissionlessBidsDisabled.selector);
        folio.bid(1, USDC, IERC20(address(USDT)), D6_TOKEN_10K, D6_TOKEN_10K * 100, false, bytes(""));
    }

    function test_auctionByMockFiller() public {
        // bid in two chunks, one at start time and one at end time

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );

        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // check prices
        (, uint256 start, uint256 end) = folio.auctions(0);

        vm.warp(start);
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt, "wrong start sell amount");
        assertEq(buyAmount, amt * 100, "wrong start buy amount"); // 100x

        // fill 1st time
        IBaseTrustedFiller fill = folio.createTrustedFill(
            0,
            USDC,
            IERC20(address(USDT)),
            cowswapFiller,
            bytes32(block.timestamp)
        );
        MockERC20(address(USDC)).burn(address(fill), amt / 2);
        MockERC20(address(USDT)).mint(address(fill), amt * 50);

        vm.warp((start + end) / 2);
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong mid sell amount");
        assertEq(buyAmount, amt / 2 + 1, "wrong mid buy amount"); // ~1x

        vm.warp(end);
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong end sell amount");
        assertEq(buyAmount, amt / 200, "wrong end buy amount"); // 1/100x

        // bid a 2nd time for the rest of the volume, at end time
        IBaseTrustedFiller swap2 = folio.createTrustedFill(
            0,
            USDC,
            IERC20(address(USDT)),
            cowswapFiller,
            bytes32(block.timestamp)
        );
        MockERC20(address(USDC)).burn(address(swap2), amt / 2);
        MockERC20(address(USDT)).mint(address(swap2), amt / 200);
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");

        // anyone should be able to close, even though it's ideal this happens in the cowswap post-hook
        folio.poke();
        assertEq(USDC.balanceOf(address(swap2)), 0, "wrong usdc balance");
        assertEq(USDT.balanceOf(address(swap2)), 0, "wrong usdt balance");

        // Folio should have balances
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong folio usdc balance");
        assertEq(USDT.balanceOf(address(folio)), amt * 50 + amt / 200, "wrong folio usdt balance");
    }

    function test_auctionIsValidSignature() public {
        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);
        bytes32 domainSeparator = 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;

        // deploy a MockEIP712 to the GPV2_SETTLEMENT address
        address mockEIP712 = address(new MockEIP712(domainSeparator));
        vm.etch(address(GPV2_SETTLEMENT), mockEIP712.code);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        (, uint256 start, uint256 end) = folio.auctions(0);
        vm.warp(start);

        // isValidSignature should succeed for the correct bid

        uint256 amt = D6_TOKEN_10K;
        IBaseTrustedFiller fill = folio.createTrustedFill(0, USDC, IERC20(address(USDT)), cowswapFiller, bytes32(0));

        GPv2OrderLib.Data memory order = GPv2OrderLib.Data({
            sellToken: USDC,
            buyToken: USDT,
            receiver: address(fill),
            sellAmount: amt,
            buyAmount: amt * 100,
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
        folio.createTrustedFill(0, USDC, IERC20(address(USDT)), cowswapFiller, bytes32(0));

        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        // Start rebalance

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // now createTrustedFill should work

        IBaseTrustedFiller fill = folio.createTrustedFill(
            0,
            USDC,
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

        fill = folio.createTrustedFill(0, USDC, IERC20(address(USDT)), cowswapFiller, bytes32(block.timestamp + 1));
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
        weights[2] = SELL;
        prices[2] = FULL_PRICE_RANGE_27;

        // Buy USDC
        weights[0] = BUY;

        uint256 amt = D27_TOKEN_10K;

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + MAX_AUCTION_LENGTH,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, MAX_AUCTION_LENGTH, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        // should have right bid at start, middle, and end of auction

        (, uint256 start, uint256 end) = folio.auctions(0);

        vm.warp(start);
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, IERC20(address(MEME)), USDC, type(uint256).max);
        assertEq(sellAmount, amt, "wrong start sell amount");
        assertEq(buyAmount, (amt * 1000) / 1e21, "wrong start buy amount"); // 1000x

        vm.warp((start + end) / 2);
        (sellAmount, buyAmount, ) = folio.getBid(0, IERC20(address(MEME)), USDC, type(uint256).max);
        assertEq(sellAmount, amt, "wrong mid sell amount");
        assertEq(buyAmount, (amt * 10) / 1e21 + 1e4, "wrong mid buy amount"); // ~10x

        vm.warp(end);
        (sellAmount, buyAmount, ) = folio.getBid(0, IERC20(address(MEME)), USDC, type(uint256).max);
        assertEq(sellAmount, amt, "wrong end sell amount");
        assertEq(buyAmount, (amt / 1e21) / 10, "wrong end buy amount"); // 1/10x
    }

    function test_auctionCloseAuctionByRebalanceManager() public {
        assets.push(address(USDT));
        weights.push(WEIGHTS_6);
        prices.push(FULL_PRICE_RANGE_6);

        uint256 amt = D6_TOKEN_10K;

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        vm.prank(user1);
        vm.expectRevert(IFolio.Folio__Unauthorized.selector);
        folio.closeAuction(1);

        (, uint256 start, uint256 end) = folio.auctions(0);

        vm.startPrank(dao);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, IERC20(address(USDT)), amt, amt, false, bytes(""));

        vm.warp(start);

        folio.closeAuction(1);

        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionClosed(0);
        folio.closeAuction(0);

        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, IERC20(address(USDT)), amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, IERC20(address(USDT)), amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, IERC20(address(USDT)), amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctionCloseAuctionByAuctionLauncher() public {
        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = SELL;

        // Buy DAI
        weights[1] = BUY;

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        vm.prank(user1);
        vm.expectRevert(IFolio.Folio__Unauthorized.selector);
        folio.closeAuction(1);

        (, uint256 start, uint256 end) = folio.auctions(0);

        vm.startPrank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, DAI, amt, amt, false, bytes(""));

        vm.warp(start);

        folio.closeAuction(1);

        folio.closeAuction(0);

        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, DAI, amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, DAI, amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, DAI, amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctionCloseAuctionByOwner() public {
        assets.push(address(USDT));
        weights.push(WEIGHTS_6);
        prices.push(FULL_PRICE_RANGE_6);

        uint256 amt = D6_TOKEN_10K;

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        (, uint256 start, uint256 end) = folio.auctions(0);

        vm.startPrank(owner);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, IERC20(address(USDT)), amt, amt, false, bytes(""));

        vm.warp(start);

        folio.closeAuction(1);

        folio.closeAuction(0);

        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, IERC20(address(USDT)), amt, amt, false, bytes(""));

        vm.warp(end);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, IERC20(address(USDT)), amt, amt, false, bytes(""));

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, IERC20(address(USDT)), amt, amt, false, bytes(""));
        vm.stopPrank();
    }

    function test_rebalanceAboveMaxTTL() public {
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidTTL.selector);
        folio.startRebalance(tokens, limits, MAX_AUCTION_LENGTH, MAX_TTL + 1);
    }

    function test_auctionNotOpenableOutsideRebalance() public {
        // should not be openable until approved

        vm.startPrank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__NotRebalancing.selector);
        folio.openAuction(0, new address[](0), new IFolio.WeightRange[](0), new IFolio.PriceRange[](0), NATIVE_LIMITS);

        vm.expectRevert(IFolio.Folio__NotRebalancing.selector);
        folio.openAuction(1, new address[](0), new IFolio.WeightRange[](0), new IFolio.PriceRange[](0), NATIVE_LIMITS);
    }

    function test_auctionUnrestrictedCallerCannotClobber() public {
        // Add USDT for auction setup
        assets.push(address(USDT));
        weights.push(WEIGHTS_6);
        prices.push(FULL_PRICE_RANGE_6);

        // Start rebalance
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Open auction
        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        // Attempt to open the same auction unrestricted
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__AuctionCannotBeOpenedWithoutRestriction.selector);
        folio.openAuctionUnrestricted(1);
    }

    function test_auctionNotLaunchableAfterTimeout() public {
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        // Start rebalance
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Warp time to just after the rebalance expires
        vm.warp(block.timestamp + MAX_TTL + 1);

        // Attempt to open an auction after the timeout
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__NotRebalancing.selector);

        // This call should revert because the rebalance period (availableUntil) has passed
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
    }

    function test_auctionNotAvailableBeforeOpen() public {
        uint256 amt = D6_TOKEN_1;

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // auction should not be biddable before openAuction

        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, DAI, amt, amt, false, bytes(""));
    }

    function test_auctionNotAvailableAfterEnd() public {
        uint256 amt = D6_TOKEN_1;

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        weights[0] = SELL;
        weights[1] = BUY;
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        // auction should not be biddable after end

        (, , uint256 end) = folio.auctions(0);

        vm.warp(end + 1);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        folio.bid(0, USDC, DAI, amt, amt, false, bytes(""));
    }

    function test_auctionBidRemovesTokenFromBasketAt0() public {
        // should not remove token from basket above 0

        uint256 amt = D6_TOKEN_10K;

        // Configure weights for selling USDC and buying DAI
        weights[0] = SELL;
        weights[1] = BUY;

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        // Start rebalance
        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Open auction
        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // Bid for most of the USDC, but not all
        vm.startPrank(user1);
        DAI.approve(address(folio), amt * 1e14);
        folio.bid(0, USDC, DAI, amt - 1, (amt - 1) * 1e14, false, bytes(""));

        // Check basket still contains USDC
        (address[] memory tripleBasket, ) = folio.toAssets(1e18, Math.Rounding.Floor);
        assertEq(tripleBasket.length, 3);
        assertEq(tripleBasket[0], address(USDC));
        assertEq(tripleBasket[1], address(DAI));
        assertEq(tripleBasket[2], address(MEME));

        // Bid for the remaining USDC
        folio.bid(0, USDC, DAI, 1, 1e14, false, bytes(""));

        // Check USDC is removed from basket
        (address[] memory doubleBasket, ) = folio.toAssets(1e18, Math.Rounding.Floor);
        assertEq(doubleBasket.length, 2);
        assertEq(doubleBasket[0], address(MEME));
        assertEq(doubleBasket[1], address(DAI));
    }

    function test_auctionBidZeroAmount() public {
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        weights[1] = BUY;
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        vm.startPrank(user1);
        USDT.approve(address(folio), 0);
        vm.expectRevert(IFolio.Folio__InsufficientBuyAvailable.selector);
        folio.bid(0, USDC, DAI, 0, 0, false, bytes(""));
    }

    function test_auctionOnlyAuctionLauncherCanBypassDelay() public {
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // cannot permissionlessly open auction during restricted perieod

        vm.expectRevert(IFolio.Folio__AuctionCannotBeOpenedWithoutRestriction.selector);
        folio.openAuctionUnrestricted(1);

        // but should be possible after auction launcher window
        (, , , , Folio.RebalanceTimestamps memory timestamps, ) = folio.getRebalance();
        vm.warp(timestamps.restrictedUntil);
        folio.openAuctionUnrestricted(1);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // and AUCTION_LAUNCHER can clobber
        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
    }

    function test_auctionOnlyConsiderTokensInRebalance() public {
        uint256 amt = D6_TOKEN_10K;

        // Sell USDC and buy DAI (only use those tokens for rebalance)
        address[] memory smallerAssets = new address[](2);
        smallerAssets[0] = assets[0];
        smallerAssets[1] = assets[1];
        IFolio.WeightRange[] memory smallerWeights = new IFolio.WeightRange[](2);
        smallerWeights[0] = SELL;
        smallerWeights[1] = BUY;
        IFolio.PriceRange[] memory smallerPrices = new IFolio.PriceRange[](2);
        smallerPrices[0] = prices[0];
        smallerPrices[1] = prices[1];

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](2);
        tokens[0] = IFolio.TokenRebalanceParams(
            smallerAssets[0],
            smallerWeights[0],
            smallerPrices[0],
            type(uint256).max,
            true
        );
        tokens[1] = IFolio.TokenRebalanceParams(
            smallerAssets[1],
            smallerWeights[1],
            smallerPrices[1],
            type(uint256).max,
            true
        );

        vm.prank(dao);
        folio.startRebalance(tokens, NATIVE_LIMITS, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Open auction unrestricted
        (, , , , Folio.RebalanceTimestamps memory timestamps, ) = folio.getRebalance();
        vm.warp(timestamps.restrictedUntil);
        folio.openAuctionUnrestricted(1);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // Bid all the USDC
        vm.startPrank(user1);
        DAI.approve(address(folio), amt * 1e14);
        folio.bid(0, USDC, DAI, amt, amt * 1e14, false, bytes(""));
    }

    function test_auctionDishonestCallback() public {
        uint256 amt = D6_TOKEN_1;

        // Sell USDC
        weights[0] = SELL;

        // Buy DAI
        weights[1] = BUY;

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // dishonest callback that returns fewer tokens than expected

        MockBidder mockBidder = new MockBidder(false);
        DAI.transfer(address(mockBidder), amt * 1e14 - 1);
        vm.prank(address(mockBidder));
        vm.expectRevert(abi.encodeWithSelector(IFolio.Folio__InsufficientBid.selector));
        folio.bid(0, USDC, DAI, amt, amt * 1e14, true, bytes(""));
    }

    function test_multipleSwapsOnSameBuyToken() public {
        // launch an auction to sell USDC/DAI for USDT

        // Sell USDC + DAI
        weights[0] = SELL;
        weights[1] = SELL;

        // Add USDT
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        uint256 amt1 = USDC.balanceOf(address(folio));
        uint256 amt2 = DAI.balanceOf(address(folio));
        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // bid in first pair auction for half volume at start

        vm.startPrank(user1);
        USDT.approve(address(folio), amt1 * 100);
        folio.bid(0, USDC, IERC20(address(USDT)), amt1, amt1 * 100, false, bytes(""));

        // bid in second pair for rest of volume at start

        vm.startPrank(user2);
        USDT.approve(address(folio), amt1 * 100);
        folio.bid(0, DAI, IERC20(address(USDT)), amt2, amt1 * 100, false, bytes(""));

        // should be empty

        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        assertEq(DAI.balanceOf(address(folio)), 0, "wrong dai balance");

        // all auction bids should now quote for 0 size since weights are in alignment with balances
        // skip USDC/DAI since they got removed from basket
        for (uint256 i = 2; i < assets.length; i++) {
            for (uint256 j = 2; j < assets.length; j++) {
                if (i == j) continue;
                (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(
                    0,
                    IERC20(assets[i]),
                    IERC20(assets[j]),
                    type(uint256).max
                );
                assertEq(sellAmount, 0, "wrong sell amount");
                assertEq(buyAmount, 0, "wrong buy amount");
            }
        }
    }

    function test_multipleSwapsOnSameSellToken() public {
        // launch an auction to sell USDC for DAI/USDT

        // Sell USDC
        weights[0] = SELL;

        // Buy DAI and USDT
        weights[1] = BUY;
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        // Start rebalance
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        uint256 amt1 = USDC.balanceOf(address(folio));

        // Open auction
        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // bid for half of sell volume for DAI at starth

        vm.startPrank(user1);
        DAI.approve(address(folio), (amt1 * 1e12 * 100) / 2);
        folio.bid(0, USDC, DAI, amt1 / 2, (amt1 * 1e12 * 100) / 2, false, bytes(""));

        // bid in second pair for rest of volume at start

        vm.startPrank(user2);
        USDT.approve(address(folio), (amt1 * 100) / 2);
        folio.bid(0, USDC, IERC20(address(USDT)), amt1 / 2, (amt1 * 100) / 2, false, bytes(""));

        // should be empty

        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");

        // all auction bids should now quote for 0 size since weights are in alignment with balances
        // skip USDC since it got removed from basket
        for (uint256 i = 1; i < assets.length; i++) {
            for (uint256 j = 1; j < assets.length; j++) {
                if (i == j) continue;
                (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(
                    0,
                    IERC20(assets[i]),
                    IERC20(assets[j]),
                    type(uint256).max
                );
                assertEq(sellAmount, 0, "wrong sell amount");
                assertEq(buyAmount, 0, "wrong buy amount");
            }
        }
    }

    function test_auctionPriceRange() public {
        // Sell USDC
        weights[0] = SELL;

        // Add USDT
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        uint256 rebalanceNonce = 1;

        for (uint256 i = MAX_TOKEN_PRICE; i > 0; i /= 10) {
            uint256 index = folio.nextAuctionId();

            IFolio.PriceRange memory priceRange = IFolio.PriceRange({
                low: (i + MAX_TOKEN_PRICE_RANGE - 1) / MAX_TOKEN_PRICE_RANGE,
                high: i
            });
            if (priceRange.low == priceRange.high) {
                priceRange.high = priceRange.low + 1;
            }

            prices[0] = priceRange;
            prices[1] = priceRange;
            prices[2] = priceRange;
            prices[3] = priceRange;

            IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
            tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
            tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
            tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
            tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

            vm.prank(dao);
            folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

            // should not revert at top or bottom end
            vm.prank(auctionLauncher);
            vm.expectEmit(true, false, false, false);
            emit IFolio.AuctionOpened(
                rebalanceNonce,
                0,
                assets,
                weights,
                prices,
                NATIVE_LIMITS,
                block.timestamp,
                block.timestamp + AUCTION_LENGTH
            );

            folio.openAuction(rebalanceNonce, assets, weights, prices, NATIVE_LIMITS);
            (, uint256 start, uint256 end) = folio.auctions(index);

            // should not revert
            vm.warp(start);
            folio.getBid(index, USDC, IERC20(address(USDT)), type(uint256).max);
            vm.warp(end);
            folio.getBid(index, USDC, IERC20(address(USDT)), type(uint256).max);

            rebalanceNonce++;
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
        weights[0] = SELL;

        // Buy USDT
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        // Start rebalance
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Open auction
        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // Attempt bid with extremely low maxBuyAmount, causing slippage revert
        vm.startPrank(user1);
        USDT.approve(address(folio), amt);
        vm.expectRevert(IFolio.Folio__SlippageExceeded.selector);
        folio.bid(0, USDC, IERC20(address(USDT)), amt, 1, false, bytes(""));
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
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Open auction for USDC -> USDT
        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // Attempt to bid for more USDC than is available in the folio.
        vm.startPrank(user1);
        uint256 excessBidAmount = usdcAvailable + 1;
        uint256 requiredUSDT = excessBidAmount;
        USDT.approve(address(folio), requiredUSDT);

        vm.expectRevert(IFolio.Folio__InsufficientSellAvailable.selector);
        folio.bid(0, USDC, IERC20(address(USDT)), excessBidAmount, requiredUSDT, false, bytes(""));
        vm.stopPrank();
    }

    function test_auctionCannotOpenAuctionWithInvalidTokens() public {
        // Start rebalance first (nonce 1)
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.startPrank(auctionLauncher);

        // Prepare valid weight/price arrays (length 2 for simplicity)
        IFolio.WeightRange[] memory validWeights = new IFolio.WeightRange[](2);
        validWeights[0] = weights[0];
        validWeights[1] = weights[1];

        IFolio.PriceRange[] memory validPrices = new IFolio.PriceRange[](2);
        validPrices[0] = prices[0];
        validPrices[1] = prices[1];

        // --- Case 1: Sell token is zero address ---
        address[] memory invalidTokens1 = new address[](2);
        invalidTokens1[0] = address(0); // Invalid sell token
        invalidTokens1[1] = address(USDC);
        // This should fail because address(0) is not part of the rebalance details.
        vm.expectRevert(IFolio.Folio__InvalidAsset.selector);
        folio.openAuction(1, invalidTokens1, validWeights, validPrices, NATIVE_LIMITS);

        // --- Case 2: Buy token is zero address ---
        address[] memory invalidTokens2 = new address[](2);
        invalidTokens2[0] = address(USDC);
        invalidTokens2[1] = address(0); // Invalid buy token
        vm.expectRevert(IFolio.Folio__InvalidAsset.selector);
        folio.openAuction(1, invalidTokens2, validWeights, validPrices, NATIVE_LIMITS);

        // --- Case 3: Sell token is the Folio address ---
        address[] memory invalidTokens3 = new address[](2);
        invalidTokens3[0] = address(folio); // Invalid sell token
        invalidTokens3[1] = address(USDC);
        vm.expectRevert(IFolio.Folio__InvalidAsset.selector);
        folio.openAuction(1, invalidTokens3, validWeights, validPrices, NATIVE_LIMITS);

        // --- Case 4: Buy token is the Folio address ---
        address[] memory invalidTokens4 = new address[](2);
        invalidTokens4[0] = address(USDC);
        invalidTokens4[1] = address(folio); // Invalid buy token
        vm.expectRevert(IFolio.Folio__InvalidAsset.selector);
        folio.openAuction(1, invalidTokens4, validWeights, validPrices, NATIVE_LIMITS);
        vm.stopPrank();
    }

    function test_auctionCannotOpenAuctionWithInvalidArrays() public {
        // Start rebalance first (nonce 1)
        weights[0] = SELL;
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.startPrank(auctionLauncher);

        // Invalid arrays
        IFolio.WeightRange[] memory smallerWeights = new IFolio.WeightRange[](3);
        smallerWeights[0] = weights[0];
        smallerWeights[1] = weights[1];
        smallerWeights[2] = weights[2];
        IFolio.PriceRange[] memory smallerPrices = new IFolio.PriceRange[](3);
        smallerPrices[0] = prices[0];
        smallerPrices[1] = prices[1];
        smallerPrices[2] = prices[2];
        vm.expectRevert(IFolio.Folio__InvalidArrayLengths.selector);
        folio.openAuction(1, assets, smallerWeights, smallerPrices, NATIVE_LIMITS);

        // Add weights and retry, same error
        vm.expectRevert(IFolio.Folio__InvalidArrayLengths.selector);
        folio.openAuction(1, assets, weights, smallerPrices, NATIVE_LIMITS);

        // Add prices, now should work
        vm.expectEmit(true, true, true, false);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp,
            block.timestamp + AUCTION_LENGTH
        );
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
    }

    function test_auctionCannotStartRebalanceOnDuplicateTokens() public {
        assets[1] = assets[0];

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.startPrank(dao);
        vm.expectRevert(IFolio.Folio__DuplicateAsset.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
    }

    function test_auctionCannotStartRebalanceWithInvalidSellLimit() public {
        // This test checks general invalid RebalanceLimits, not just sell limits.
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.startPrank(dao);

        // --- Case 1: limits.low == 0 ---
        IFolio.RebalanceLimits memory invalidLimits1 = IFolio.RebalanceLimits({
            low: 0, // Invalid: low must be > 0
            spot: 1,
            high: MAX_LIMIT
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(tokens, invalidLimits1, MAX_AUCTION_LENGTH, MAX_TTL);

        // --- Case 2: limits.low > limits.spot ---
        IFolio.RebalanceLimits memory invalidLimits2 = IFolio.RebalanceLimits({
            low: 2,
            spot: 1, // Invalid: spot < low
            high: MAX_LIMIT
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(tokens, invalidLimits2, MAX_AUCTION_LENGTH, MAX_TTL);

        // --- Case 3: limits.spot > limits.high ---
        IFolio.RebalanceLimits memory invalidLimits3 = IFolio.RebalanceLimits({
            low: 1,
            spot: MAX_LIMIT,
            high: MAX_LIMIT - 1 // Invalid: high < spot
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(tokens, invalidLimits3, MAX_AUCTION_LENGTH, MAX_TTL);

        // --- Case 4: limits.high > MAX_LIMIT ---
        IFolio.RebalanceLimits memory invalidLimits4 = IFolio.RebalanceLimits({
            low: 1,
            spot: 1,
            high: MAX_LIMIT + 1 // Invalid: high > MAX_LIMIT
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(tokens, invalidLimits4, MAX_AUCTION_LENGTH, MAX_TTL);

        vm.stopPrank();
    }

    function test_auctionCannotStartRebalanceWithInvalidBuyLimit() public {
        // This test checks general invalid RebalanceLimits, similar to the previous test.
        // The name is kept for historical reasons, but it tests the same constraints.
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.startPrank(dao);

        // --- Case 1: limits.low > limits.high ---
        IFolio.RebalanceLimits memory invalidLimits1 = IFolio.RebalanceLimits({
            low: MAX_LIMIT, // Low is high
            spot: MAX_LIMIT,
            high: MAX_LIMIT - 1 // High is lower than low
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(tokens, invalidLimits1, MAX_AUCTION_LENGTH, MAX_TTL);

        // --- Case 2: limits.high > MAX_LIMIT (Redundant, but kept for clarity) ---
        IFolio.RebalanceLimits memory invalidLimits2 = IFolio.RebalanceLimits({
            low: 1,
            spot: 1,
            high: MAX_LIMIT + 1 // High exceeds maximum
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(tokens, invalidLimits2, MAX_AUCTION_LENGTH, MAX_TTL);

        // --- Case 3: limits.spot < limits.low (Redundant, but kept for clarity) ---
        IFolio.RebalanceLimits memory invalidLimits3 = IFolio.RebalanceLimits({
            low: 10, // Low is 10
            spot: 5, // Spot is less than low
            high: MAX_LIMIT
        });
        vm.expectRevert(IFolio.Folio__InvalidLimits.selector);
        folio.startRebalance(tokens, invalidLimits3, MAX_AUCTION_LENGTH, MAX_TTL);

        vm.stopPrank();
    }

    function test_auctionCannotOpenAuctionWithInvalidPrices() public {
        // Start rebalance
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.startPrank(auctionLauncher);

        // Prepare valid base parameters
        address[] memory auctionAddresses = new address[](2);
        auctionAddresses[0] = address(USDC);
        auctionAddresses[1] = address(DAI);

        IFolio.WeightRange[] memory newWeights = new IFolio.WeightRange[](2);
        newWeights[0] = weights[0];
        newWeights[1] = weights[1];

        IFolio.PriceRange[] memory invalidPrices = new IFolio.PriceRange[](2);
        invalidPrices[1] = prices[1]; // Keep DAI price valid for these tests

        // --- Case 1: Low price is zero ---
        invalidPrices[0] = IFolio.PriceRange({ low: 0, high: 1e16 }); // Invalid low = 0
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, auctionAddresses, newWeights, invalidPrices, NATIVE_LIMITS);

        // --- Case 2: Low price greater than high price ---
        invalidPrices[0] = IFolio.PriceRange({ low: 1e16, high: 1e15 }); // Invalid low > high
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, auctionAddresses, newWeights, invalidPrices, NATIVE_LIMITS);

        // --- Case 3: High price exceeds MAX_TOKEN_PRICE ---
        invalidPrices[0] = IFolio.PriceRange({ low: 1e16, high: MAX_TOKEN_PRICE + 1 }); // Invalid high > max
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, auctionAddresses, newWeights, invalidPrices, NATIVE_LIMITS);

        // --- Case 4: High price exceeds range limit relative to low price ---
        uint256 lowPrice = 1e15;
        invalidPrices[0] = IFolio.PriceRange({ low: lowPrice, high: MAX_TOKEN_PRICE_RANGE * lowPrice + 1 }); // Invalid high > range * low
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, auctionAddresses, newWeights, invalidPrices, NATIVE_LIMITS);
        vm.stopPrank();
    }

    function test_auctionCannotRebalanceIfFolioDeprecated() public {
        vm.prank(owner);
        folio.deprecateFolio();

        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__FolioDeprecated.selector);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
    }

    function test_auctionCannotBidIfFolioDeprecated() public {
        weights[1] = BUY;

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        vm.prank(owner);
        folio.deprecateFolio();

        vm.warp(block.timestamp + AUCTION_WARMUP);

        vm.expectRevert(IFolio.Folio__FolioDeprecated.selector);
        folio.bid(0, USDC, IERC20(address(USDT)), 1e27, 1e27, false, bytes(""));
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

    function test_cannotMixAtomicSwaps() public {
        // make atomic swappable
        vm.prank(owner);
        folio.setRebalanceControl(
            IFolio.RebalanceControl({ weightControl: false, priceControl: IFolio.PriceControl.ATOMIC_SWAP })
        );

        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Try to open auction with mixed prices - all valid price points but mixing atomic and non-atomic
        prices[0] = PRICE_POINT_6; // Atomic swap price point
        prices[1] = PRICE_POINT_18; // Atomic swap price point
        prices[2] = PRICE_POINT_27; // Atomic swap price point
        prices[3] = FULL_PRICE_RANGE_6; // Regular price range - this should cause the revert

        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__MixedAtomicSwaps.selector);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
    }

    function test_endRebalance() public {
        // Setup initial rebalance
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Open an auction
        vm.prank(auctionLauncher);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // Attempt to end rebalance with unauthorized role (user1)
        vm.prank(user1);
        vm.expectRevert(IFolio.Folio__Unauthorized.selector);
        folio.endRebalance();

        // End the rebalance with authorized role (dao)
        vm.prank(dao);
        vm.expectEmit(true, false, false, true);
        emit IFolio.RebalanceEnded(1);
        folio.endRebalance();

        // Verify we can still bid on the existing auction
        vm.startPrank(user1);
        USDT.approve(address(folio), (D6_TOKEN_10K / 2) * 100);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), D6_TOKEN_10K / 2, (D6_TOKEN_10K / 2) * 100);
        folio.bid(0, USDC, IERC20(address(USDT)), D6_TOKEN_10K / 2, (D6_TOKEN_10K / 2) * 100, false, bytes(""));
        vm.stopPrank();

        // Verify we cannot open a new auction
        vm.prank(auctionLauncher);
        vm.expectRevert(IFolio.Folio__NotRebalancing.selector);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
    }

    function test_priceControlAuctionBidWithoutCallback() public {
        // bid in two chunks, one at start time and one at end time

        // Set Rebalance PriceControl.PARTIAL
        vm.prank(owner);
        folio.setRebalanceControl(
            IFolio.RebalanceControl({ weightControl: false, priceControl: IFolio.PriceControl.PARTIAL })
        );

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.PARTIAL,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Reduce price range for all tokens
        for (uint256 i = 0; i < prices.length; i++) {
            prices[i] = IFolio.PriceRange({ low: prices[i].low * 2, high: prices[i].high / 2 });
        }

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // bid once at start time
        vm.startPrank(user1);
        USDT.approve(address(folio), (amt / 2) * 25);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, (amt / 2) * 25);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, (amt / 2) * 25, false, bytes(""));

        (, uint256 start, uint256 end) = folio.auctions(0);

        vm.warp(start);
        vm.startSnapshotGas("getBid()");
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        vm.stopSnapshotGas();
        assertEq(sellAmount, amt / 2, "wrong start sell amount");
        assertEq(buyAmount, (amt / 2) * 25, "wrong start buy amount");

        vm.warp((start + end) / 2);
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong mid sell amount");
        assertEq(buyAmount, (amt / 2) + 1, "wrong mid buy amount");

        vm.warp(end);
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong end sell amount");
        assertEq(buyAmount, (amt / 2) / 25, "wrong end buy amount");

        // bid a 2nd time for the rest of the volume, at end time
        USDT.approve(address(folio), (amt / 2) / 25);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, (amt / 2) / 25);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, (amt / 2) / 25, false, bytes(""));
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_priceControlAuctionBidWithCallback() public {
        // bid in two chunks, one at start time and one at end time

        // Set Rebalance PriceControl.PARTIAL
        vm.prank(owner);
        folio.setRebalanceControl(
            IFolio.RebalanceControl({ weightControl: false, priceControl: IFolio.PriceControl.PARTIAL })
        );

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.PARTIAL,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Reduce price range for all tokens
        for (uint256 i = 0; i < prices.length; i++) {
            prices[i] = IFolio.PriceRange({ low: prices[i].low * 2, high: prices[i].high / 2 });
        }

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // bid once at start time
        MockBidder mockBidder = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder), (amt / 2) * 25);
        vm.prank(address(mockBidder));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, (amt / 2) * 25);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, (amt / 2) * 25, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        // check prices
        (, uint256 start, uint256 end) = folio.auctions(0);

        vm.warp(start);
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong start sell amount");
        assertEq(buyAmount, (amt / 2) * 25, "wrong start buy amount"); // 25x

        vm.warp((start + end) / 2);
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong mid sell amount");
        assertEq(buyAmount, amt / 2 + 1, "wrong mid buy amount"); // ~1x

        vm.warp(end);
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, amt / 2, "wrong end sell amount");
        assertEq(buyAmount, (amt / 2) / 25, "wrong end buy amount"); // 1/25x

        // bid a 2nd time for the rest of the volume, at end time
        MockBidder mockBidder2 = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder2), (amt / 2) / 25);
        vm.prank(address(mockBidder2));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), amt / 2, (amt / 2) / 25);
        folio.bid(0, USDC, IERC20(address(USDT)), amt / 2, (amt / 2) / 25, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder2)), 0, "wrong mock bidder2 balance");
        assertEq(USDC.balanceOf(address(folio)), 0, "wrong usdc balance");
        vm.stopPrank();
    }

    function test_priceControlPartialValidations() public {
        // Set rebalance control to PARTIAL
        vm.prank(owner);
        folio.setRebalanceControl(
            IFolio.RebalanceControl({ weightControl: false, priceControl: IFolio.PriceControl.PARTIAL })
        );

        // Setup basic auction parameters
        weights[0] = SELL;
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        // Start rebalance
        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Test cases for price validations
        vm.startPrank(auctionLauncher);

        // Reduce price range for all tokens
        uint256 origPriceLow = prices[0].low;
        uint256 origPriceHigh = prices[0].high;

        // 1. Test: startPrice == endPrice
        prices[0].high = prices[0].low;
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        prices[0].high = origPriceHigh;

        // // 2. Test: startPrice outside range
        prices[0].low = origPriceLow - 1; // Too low
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        prices[0].low = origPriceLow;

        // 3. Test: endPrice outside range
        prices[0].high = origPriceHigh + 1; // Too high
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        prices[0].high = origPriceHigh;

        // 4. Test: startPrice < endPrice
        prices[0] = IFolio.PriceRange({ low: origPriceHigh, high: origPriceLow }); // Low > High
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        prices[0] = IFolio.PriceRange({ low: origPriceLow, high: origPriceHigh });

        // 5. Test: Valid case should work
        // Reduce price ranges for all tokens
        for (uint256 i = 0; i < prices.length; i++) {
            prices[i] = IFolio.PriceRange({ low: prices[i].low * 2, high: prices[i].high / 2 });
        }

        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
    }

    function test_weightControlAuctionBidWithoutCallback() public {
        // bid in two chunks, one at mid time and one at end time

        // Set Rebalance weightControl = true
        vm.prank(owner);
        folio.setRebalanceControl(
            IFolio.RebalanceControl({ weightControl: true, priceControl: IFolio.PriceControl.NONE })
        );

        // Change weights range for all tokens, keep a range of 10% on each side
        for (uint256 i = 0; i < weights.length; i++) {
            weights[i] = IFolio.WeightRange({
                low: (weights[i].spot * 90) / 100,
                spot: weights[i].spot,
                high: (weights[i].spot * 110) / 100
            });
        }

        uint256 amt = D6_TOKEN_10K;

        // Start as BUY and change to SELL later
        weights[0] = BUY_FULL_RANGE;

        // Add USDT to buy
        IFolio.WeightRange memory WEIGHTS_BUY_6 = IFolio.WeightRange({ low: 9e14, spot: 1e15, high: 11e14 }); // D27{tok/BU}

        assets.push(address(USDT));
        weights.push(WEIGHTS_BUY_6);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            NATIVE_LIMITS,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, NATIVE_LIMITS, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Reduce weight range for all tokens, keep a range of 5% on each side
        for (uint256 i = 0; i < weights.length; i++) {
            weights[i] = IFolio.WeightRange({
                low: (weights[i].spot * 95) / 100,
                spot: weights[i].spot,
                high: (weights[i].spot * 105) / 100
            });
        }

        // Sell USDC
        weights[0] = SELL;

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        vm.warp(block.timestamp + AUCTION_WARMUP);

        // check prices
        (, uint256 start, uint256 end) = folio.auctions(0);

        vm.warp(start);
        vm.startSnapshotGas("getBid()");
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        vm.stopSnapshotGas();
        assertEq(sellAmount, (amt * 95) / 10000, "wrong start sell amount"); // can sell less than 1% at start
        assertEq(buyAmount, (amt * 95) / 100, "wrong start buy amount");

        vm.warp((start + end) / 2);
        uint256 midBidSellAmount = ((amt * 95) / 100); // 95% of the total volume
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertApproxEqAbs(sellAmount, midBidSellAmount, 1, "wrong mid sell amount");
        assertApproxEqAbs(buyAmount, midBidSellAmount, 1, "wrong mid buy amount");

        // bid at halfway point for full 95%
        vm.startPrank(user1);
        USDT.approve(address(folio), buyAmount);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), sellAmount, buyAmount);
        folio.bid(0, USDC, IERC20(address(USDT)), sellAmount, buyAmount, false, bytes(""));

        // auction should be empty
        vm.warp(end);
        (sellAmount, buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, 0, "wrong end sell amount");
        assertEq(buyAmount, 0, "wrong end buy amount");
    }

    function test_weightControlAuctionBidWithCallback() public {
        // bid in two chunks, one at mid time and one at end time

        // Set Rebalance weightControl = true
        vm.prank(owner);
        folio.setRebalanceControl(
            IFolio.RebalanceControl({ weightControl: true, priceControl: IFolio.PriceControl.NONE })
        );

        // Change weights range for all tokens, keep a range of 10% on each side
        for (uint256 i = 0; i < weights.length; i++) {
            weights[i] = IFolio.WeightRange({
                low: (weights[i].spot * 90) / 100,
                spot: weights[i].spot,
                high: (weights[i].spot * 110) / 100
            });
        }

        uint256 amt = D6_TOKEN_10K;

        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        IFolio.WeightRange memory WEIGHTS_BUY_6 = IFolio.WeightRange({ low: 9e14, spot: 1e15, high: 11e14 }); // D27{tok/BU}

        assets.push(address(USDT));
        weights.push(WEIGHTS_BUY_6);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            NATIVE_LIMITS,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, NATIVE_LIMITS, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Reduce weight range for all tokens, keep a range of 5% on each side
        for (uint256 i = 0; i < weights.length; i++) {
            weights[i] = IFolio.WeightRange({
                low: (weights[i].spot * 95) / 100,
                spot: weights[i].spot,
                high: (weights[i].spot * 105) / 100
            });
        }

        vm.prank(auctionLauncher);
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );

        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);

        (, uint256 start, uint256 end) = folio.auctions(0);

        // bid at halfway point for full volume
        vm.warp((start + end) / 2);
        uint256 midBidSellAmount = ((amt * 95) / 100) - 1; // 95% of the total volume
        MockBidder mockBidder = new MockBidder(true);
        vm.prank(user1);
        USDT.transfer(address(mockBidder), midBidSellAmount + 1);
        vm.prank(address(mockBidder));
        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionBid(0, address(USDC), address(USDT), midBidSellAmount, midBidSellAmount + 1);
        folio.bid(0, USDC, IERC20(address(USDT)), midBidSellAmount, midBidSellAmount + 1, true, bytes(""));
        assertEq(USDT.balanceOf(address(mockBidder)), 0, "wrong mock bidder balance");

        // auction should be empty
        vm.warp(end);
        (uint256 sellAmount, uint256 buyAmount, ) = folio.getBid(0, USDC, IERC20(address(USDT)), amt);
        assertEq(sellAmount, 0, "wrong end sell amount");
        assertEq(buyAmount, 0, "wrong end buy amount");
    }

    function test_weightControlValidations() public {
        // Set Rebalance weightControl = true
        vm.prank(owner);
        folio.setRebalanceControl(
            IFolio.RebalanceControl({ weightControl: true, priceControl: IFolio.PriceControl.NONE })
        );

        // Change weights range for all tokens, keep a range of 10% on each side
        for (uint256 i = 0; i < weights.length; i++) {
            weights[i] = IFolio.WeightRange({
                low: (weights[i].spot * 90) / 100,
                spot: weights[i].spot,
                high: (weights[i].spot * 110) / 100
            });
        }

        // Add USDT to buy
        IFolio.WeightRange memory WEIGHTS_BUY_6 = IFolio.WeightRange({ low: 9e14, spot: 1e15, high: 11e14 }); // D27{tok/BU}

        // Setup basic auction parameters
        weights[0] = SELL;
        assets.push(address(USDT));
        weights.push(WEIGHTS_BUY_6);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        // Start rebalance
        vm.prank(dao);
        folio.startRebalance(tokens, NATIVE_LIMITS, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Test cases for price validations
        vm.startPrank(auctionLauncher);

        // Reduce price range for all tokens
        uint256 origWeightLow = weights[3].low;
        uint256 origWeightHigh = weights[3].high;

        // 1. Test: weightSpot > weightHigh
        weights[3].high = weights[3].low;
        vm.expectRevert(IFolio.Folio__InvalidWeights.selector);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        weights[3].high = origWeightHigh;

        // 2. Test: weightSpot < weightLow
        weights[3].low = weights[3].high;
        vm.expectRevert(IFolio.Folio__InvalidWeights.selector);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        weights[3].low = origWeightLow;

        // 3. Test: weightLow outside range
        weights[3].low = origWeightLow - 1; // Too low
        vm.expectRevert(IFolio.Folio__InvalidWeights.selector);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        weights[3].low = origWeightLow;

        // 4. Test: weightHigh outside range
        weights[3].high = origWeightHigh + 1; // Too high
        vm.expectRevert(IFolio.Folio__InvalidWeights.selector);
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
        weights[3].high = origWeightHigh;

        // 5. Test: Valid case should work
        // Reduce weight range for all tokens, keep a range of 5% on each side
        for (uint256 i = 0; i < weights.length; i++) {
            weights[i] = IFolio.WeightRange({
                low: (weights[i].spot * 95) / 100,
                spot: weights[i].spot,
                high: (weights[i].spot * 105) / 100
            });
        }

        vm.expectEmit(true, false, false, true);
        emit IFolio.AuctionOpened(
            1,
            0,
            assets,
            weights,
            prices,
            NATIVE_LIMITS,
            block.timestamp + AUCTION_WARMUP,
            block.timestamp + AUCTION_WARMUP + AUCTION_LENGTH
        );
        folio.openAuction(1, assets, weights, prices, NATIVE_LIMITS);
    }

    function test_cannotStartRebalanceInvalidArrays() public {
        // Sell USDC
        weights[0] = SELL;

        // Add USDT to buy
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);
        vm.prank(dao);
        vm.expectEmit(address(folio));
        emit IFolio.RebalanceStarted(
            1,
            IFolio.PriceControl.NONE,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + AUCTION_LAUNCHER_WINDOW,
            block.timestamp + MAX_TTL,
            true
        );
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
    }

    function test_cannotStartRebalanceWithInvalidAsset() public {
        // Sell USDC
        weights[0] = SELL;

        // Add invalid token
        assets.push(address(0));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidAsset.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
    }

    function test_cannotStartRebalanceWithInvalidWeights() public {
        // Sell USDC
        weights[0] = SELL;

        // Add invalid token
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        // Change weights range for all tokens, keep a range of 10% on each side
        for (uint256 i = 0; i < weights.length; i++) {
            weights[i] = IFolio.WeightRange({
                low: (weights[i].spot * 90) / 100,
                spot: weights[i].spot,
                high: (weights[i].spot * 110) / 100
            });
        }

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidWeights.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Set weightControl = true
        vm.prank(owner);
        folio.setRebalanceControl(
            IFolio.RebalanceControl({ weightControl: true, priceControl: IFolio.PriceControl.NONE })
        );

        // Setup invalid weights
        uint256 origWeightHigh = weights[3].high;
        uint256 origWeightLow = weights[3].low;
        weights[3].high = weights[3].low;
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidWeights.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
        weights[3].high = origWeightHigh;

        // Setup zero weight
        weights[3].low = 0;
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], prices[3], type(uint256).max, true);
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidWeights.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
        weights[3].low = origWeightLow;
    }

    function test_cannotStartRebalanceWithInvalidPrices() public {
        // Sell USDC
        weights[0] = SELL;

        // Add invalid token
        assets.push(address(USDT));
        weights.push(BUY);
        prices.push(FULL_PRICE_RANGE_6);

        IFolio.PriceRange[] memory invalidPrices = new IFolio.PriceRange[](4);
        invalidPrices[0] = prices[0];
        invalidPrices[1] = prices[1];
        invalidPrices[2] = prices[3];
        invalidPrices[3] = prices[3];

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);

        // --- Case 1: Low price is zero ---
        invalidPrices[0] = IFolio.PriceRange({ low: 0, high: 1e16 }); // Invalid low = 0
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], invalidPrices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], invalidPrices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], invalidPrices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], invalidPrices[3], type(uint256).max, true);
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // --- Case 2: Low price greater than high price ---
        invalidPrices[0] = IFolio.PriceRange({ low: 1e16, high: 1e15 }); // Invalid low > high
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], invalidPrices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], invalidPrices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], invalidPrices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], invalidPrices[3], type(uint256).max, true);
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // --- Case 3: High price exceeds MAX_TOKEN_PRICE ---
        invalidPrices[0] = IFolio.PriceRange({ low: 1e16, high: MAX_TOKEN_PRICE + 1 }); // Invalid high > max
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], invalidPrices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], invalidPrices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], invalidPrices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], invalidPrices[3], type(uint256).max, true);
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // --- Case 4: High price exceeds range limit relative to low price ---
        uint256 lowPrice = 1e15;
        invalidPrices[0] = IFolio.PriceRange({ low: lowPrice, high: MAX_TOKEN_PRICE_RANGE * lowPrice + 1 }); // Invalid high > range * low
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], invalidPrices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], invalidPrices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], invalidPrices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(assets[3], weights[3], invalidPrices[3], type(uint256).max, true);
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__InvalidPrices.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
        vm.stopPrank();
    }
}
