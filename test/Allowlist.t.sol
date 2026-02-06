// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio } from "contracts/Folio.sol";
import { AUCTION_WARMUP, D27, MAX_AUCTION_LENGTH, MAX_TTL, MAX_WEIGHT, MAX_LIMIT } from "@utils/Constants.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { FolioProxyAdmin } from "contracts/folio/FolioProxy.sol";
import "./base/BaseTest.sol";

contract AllowlistTest is BaseTest {
    uint256 internal constant INITIAL_SUPPLY = D18_TOKEN_10K;
    uint256 internal constant AUCTION_LAUNCHER_WINDOW = MAX_TTL / 2;
    uint256 internal constant AUCTION_LENGTH = 1800; // {s} 30 min

    IFolio.WeightRange internal SELL = IFolio.WeightRange({ low: 0, spot: 0, high: 0 });
    IFolio.WeightRange internal BUY = IFolio.WeightRange({ low: MAX_WEIGHT, spot: MAX_WEIGHT, high: MAX_WEIGHT });

    IFolio.WeightRange internal WEIGHTS_6 = IFolio.WeightRange({ low: 1e15, spot: 1e15, high: 1e15 });
    IFolio.WeightRange internal WEIGHTS_18 = IFolio.WeightRange({ low: 1e27, spot: 1e27, high: 1e27 });
    IFolio.WeightRange internal WEIGHTS_27 = IFolio.WeightRange({ low: 1e36, spot: 1e36, high: 1e36 });

    IFolio.PriceRange internal FULL_PRICE_RANGE_6 = IFolio.PriceRange({ low: 1e20, high: 1e22 });
    IFolio.PriceRange internal FULL_PRICE_RANGE_18 = IFolio.PriceRange({ low: 1e8, high: 1e10 });
    IFolio.PriceRange internal FULL_PRICE_RANGE_27 = IFolio.PriceRange({ low: 1, high: 100 });

    uint256 internal constant ONE_BU = 1e18;
    IFolio.RebalanceLimits internal TRACKING_LIMITS = IFolio.RebalanceLimits({ low: 1, spot: ONE_BU, high: MAX_LIMIT });

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
            0,
            0,
            owner,
            dao,
            auctionLauncher
        );
        vm.stopPrank();
    }

    // ========== Allowlist Defaults ==========

    function test_allowlistDisabledByDefault() public view {
        assertFalse(folio.tradeAllowlistEnabled(), "allowlist should be disabled by default");
        address[] memory allowlist = folio.getTokenAllowlist();
        assertEq(allowlist.length, 0, "allowlist should be empty by default");
    }

    // ========== setTradeAllowlistEnabled ==========

    function test_setTradeAllowlistEnabled() public {
        vm.startPrank(owner);

        vm.expectEmit(address(folio));
        emit IFolio.TradeAllowlistEnabled(true);
        folio.setTradeAllowlistEnabled(true);
        assertTrue(folio.tradeAllowlistEnabled(), "allowlist should be enabled");

        vm.expectEmit(address(folio));
        emit IFolio.TradeAllowlistEnabled(false);
        folio.setTradeAllowlistEnabled(false);
        assertFalse(folio.tradeAllowlistEnabled(), "allowlist should be disabled");

        vm.stopPrank();
    }

    function test_cannotSetTradeAllowlistEnabledIfNotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.setTradeAllowlistEnabled(true);
        vm.stopPrank();

        // REBALANCE_MANAGER cannot set allowlist
        vm.startPrank(dao);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                dao,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.setTradeAllowlistEnabled(true);
        vm.stopPrank();
    }

    // ========== addToAllowlist / removeFromAllowlist ==========

    function test_addToAllowlist() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(DAI);

        vm.startPrank(owner);

        vm.expectEmit(address(folio));
        emit IFolio.TradeAllowlistTokenAdded(address(USDC));
        vm.expectEmit(address(folio));
        emit IFolio.TradeAllowlistTokenAdded(address(DAI));
        folio.addToAllowlist(tokens);

        assertTrue(folio.isTokenAllowlisted(address(USDC)), "USDC should be allowlisted");
        assertTrue(folio.isTokenAllowlisted(address(DAI)), "DAI should be allowlisted");
        assertFalse(folio.isTokenAllowlisted(address(MEME)), "MEME should not be allowlisted");

        address[] memory allowlist = folio.getTokenAllowlist();
        assertEq(allowlist.length, 2, "allowlist should have 2 tokens");

        vm.stopPrank();
    }

    function test_addToAllowlist_noDuplicateEvents() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);

        vm.startPrank(owner);

        // First add emits event
        vm.expectEmit(address(folio));
        emit IFolio.TradeAllowlistTokenAdded(address(USDC));
        folio.addToAllowlist(tokens);

        // Second add of the same token should NOT emit (EnumerableSet.add returns false)
        vm.recordLogs();
        folio.addToAllowlist(tokens);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0, "should not emit event for duplicate add");

        // Allowlist should still have only 1 token
        address[] memory allowlist = folio.getTokenAllowlist();
        assertEq(allowlist.length, 1, "allowlist should still have 1 token");

        vm.stopPrank();
    }

    function test_removeFromAllowlist() public {
        address[] memory tokensToAdd = new address[](3);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);
        tokensToAdd[2] = address(MEME);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        assertEq(folio.getTokenAllowlist().length, 3, "allowlist should have 3 tokens");

        address[] memory tokensToRemove = new address[](1);
        tokensToRemove[0] = address(DAI);

        vm.expectEmit(address(folio));
        emit IFolio.TradeAllowlistTokenRemoved(address(DAI));
        folio.removeFromAllowlist(tokensToRemove);

        assertTrue(folio.isTokenAllowlisted(address(USDC)), "USDC should still be allowlisted");
        assertFalse(folio.isTokenAllowlisted(address(DAI)), "DAI should not be allowlisted");
        assertTrue(folio.isTokenAllowlisted(address(MEME)), "MEME should still be allowlisted");
        assertEq(folio.getTokenAllowlist().length, 2, "allowlist should have 2 tokens");

        vm.stopPrank();
    }

    function test_removeFromAllowlist_noEventForNonExistent() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);

        vm.startPrank(owner);

        // Remove non-existent token should NOT emit
        vm.recordLogs();
        folio.removeFromAllowlist(tokens);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0, "should not emit event for non-existent removal");

        vm.stopPrank();
    }

    function test_cannotAddToAllowlistIfNotOwner() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.addToAllowlist(tokens);
        vm.stopPrank();
    }

    function test_cannotRemoveFromAllowlistIfNotOwner() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                folio.DEFAULT_ADMIN_ROLE()
            )
        );
        folio.removeFromAllowlist(tokens);
        vm.stopPrank();
    }

    // ========== Rebalance with Allowlist Disabled ==========

    function test_rebalance_allowlistDisabled_noRestrictions() public {
        // With allowlist disabled, any tokens can be used freely
        assertFalse(folio.tradeAllowlistEnabled(), "allowlist should be disabled");

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Verify rebalance started
        (uint256 nonce, , , , , ) = folio.getRebalance();
        assertEq(nonce, 1, "rebalance nonce should be 1");
    }

    // ========== Rebalance with Allowlist Enabled ==========

    function test_rebalance_allowlistEnabled_allTokensAllowlisted() public {
        // Allowlist all basket tokens, then rebalance normally
        address[] memory tokensToAdd = new address[](3);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);
        tokensToAdd[2] = address(MEME);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        folio.setTradeAllowlistEnabled(true);
        vm.stopPrank();

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        (uint256 nonce, , , , , ) = folio.getRebalance();
        assertEq(nonce, 1, "rebalance should have started");
    }

    function test_rebalance_allowlistEnabled_rejectsNonAllowlistedTokenWithNonZeroWeights() public {
        // Only allowlist USDC and DAI, not MEME
        address[] memory tokensToAdd = new address[](2);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        folio.setTradeAllowlistEnabled(true);
        vm.stopPrank();

        // Try to rebalance with MEME having non-zero weights -- should revert
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true); // MEME with non-zero weights

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__TokenNotAllowlisted.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
    }

    function test_rebalance_allowlistEnabled_nonAllowlistedTokenCanBeTradedOutWithZeroWeights() public {
        // Only allowlist USDC and DAI, not MEME
        address[] memory tokensToAdd = new address[](2);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        folio.setTradeAllowlistEnabled(true);
        vm.stopPrank();

        // MEME with SELL (zero) weights -- should succeed (trading out)
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], SELL, prices[2], type(uint256).max, true); // MEME with zero weights

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        (uint256 nonce, , , , , ) = folio.getRebalance();
        assertEq(nonce, 1, "rebalance should have started");
    }

    function test_rebalance_allowlistEnabled_rejectsPartiallyZeroWeights() public {
        // Non-allowlisted token must have ALL three weight components zero
        address[] memory tokensToAdd = new address[](2);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        folio.setTradeAllowlistEnabled(true);
        vm.stopPrank();

        // MEME with only low non-zero
        IFolio.WeightRange memory lowOnly = IFolio.WeightRange({ low: 1e36, spot: 0, high: 0 });

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], lowOnly, prices[2], type(uint256).max, true);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__TokenNotAllowlisted.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Also test with only high non-zero
        IFolio.WeightRange memory highOnly = IFolio.WeightRange({ low: 0, spot: 0, high: 1e36 });

        tokens[2] = IFolio.TokenRebalanceParams(assets[2], highOnly, prices[2], type(uint256).max, true);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__TokenNotAllowlisted.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Also test with only spot non-zero
        IFolio.WeightRange memory spotOnly = IFolio.WeightRange({ low: 0, spot: 1e36, high: 0 });

        tokens[2] = IFolio.TokenRebalanceParams(assets[2], spotOnly, prices[2], type(uint256).max, true);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__TokenNotAllowlisted.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
    }

    // ========== Token Removed from Allowlist ==========

    function test_rebalance_tokenRemovedFromAllowlist_canTradeOut() public {
        // Add all tokens to allowlist initially
        address[] memory tokensToAdd = new address[](3);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);
        tokensToAdd[2] = address(MEME);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        folio.setTradeAllowlistEnabled(true);

        // Remove MEME from allowlist
        address[] memory tokensToRemove = new address[](1);
        tokensToRemove[0] = address(MEME);
        folio.removeFromAllowlist(tokensToRemove);
        vm.stopPrank();

        assertFalse(folio.isTokenAllowlisted(address(MEME)), "MEME should not be allowlisted");

        // Rebalance with MEME having zero weights (trade out) -- should succeed
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], SELL, prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        (uint256 nonce, , , , , ) = folio.getRebalance();
        assertEq(nonce, 1, "rebalance should have started");
    }

    function test_rebalance_tokenRemovedFromAllowlist_cannotIncreaseHolding() public {
        // Add all tokens to allowlist initially
        address[] memory tokensToAdd = new address[](3);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);
        tokensToAdd[2] = address(MEME);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        folio.setTradeAllowlistEnabled(true);

        // Remove MEME from allowlist
        address[] memory tokensToRemove = new address[](1);
        tokensToRemove[0] = address(MEME);
        folio.removeFromAllowlist(tokensToRemove);
        vm.stopPrank();

        // Rebalance with MEME having non-zero weights (trying to buy) -- should revert
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__TokenNotAllowlisted.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
    }

    // ========== Re-adding Token to Allowlist ==========

    function test_rebalance_readdedTokenCanBeUsedNormally() public {
        address[] memory tokensToAdd = new address[](2);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        folio.setTradeAllowlistEnabled(true);
        vm.stopPrank();

        // MEME is not allowlisted, rebalance with non-zero weights should fail
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__TokenNotAllowlisted.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Now add MEME to allowlist
        address[] memory addMeme = new address[](1);
        addMeme[0] = address(MEME);
        vm.prank(owner);
        folio.addToAllowlist(addMeme);

        // Should succeed now
        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        (uint256 nonce, , , , , ) = folio.getRebalance();
        assertEq(nonce, 1, "rebalance should have started");
    }

    // ========== Disabling Allowlist Removes Restrictions ==========

    function test_rebalance_disablingAllowlistRemovesRestrictions() public {
        // Enable allowlist with only USDC and DAI
        address[] memory tokensToAdd = new address[](2);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        folio.setTradeAllowlistEnabled(true);
        vm.stopPrank();

        // MEME not allowlisted with non-zero weights should fail
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__TokenNotAllowlisted.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        // Disable allowlist
        vm.prank(owner);
        folio.setTradeAllowlistEnabled(false);

        // Should now succeed even with MEME having non-zero weights
        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        (uint256 nonce, , , , , ) = folio.getRebalance();
        assertEq(nonce, 1, "rebalance should have started");
    }

    // ========== Adding New Token (USDT) to Rebalance ==========

    function test_rebalance_allowlistEnabled_newTokenMustBeAllowlisted() public {
        // Allowlist existing basket tokens
        address[] memory tokensToAdd = new address[](3);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);
        tokensToAdd[2] = address(MEME);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        folio.setTradeAllowlistEnabled(true);
        vm.stopPrank();

        // Try to add USDT (not in allowlist) with non-zero weights
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], SELL, prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(address(USDT), BUY, FULL_PRICE_RANGE_6, type(uint256).max, true);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__TokenNotAllowlisted.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
    }

    function test_rebalance_allowlistEnabled_newAllowlistedTokenSucceeds() public {
        // Allowlist existing basket tokens AND USDT
        address[] memory tokensToAdd = new address[](4);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);
        tokensToAdd[2] = address(MEME);
        tokensToAdd[3] = address(USDT);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        folio.setTradeAllowlistEnabled(true);
        vm.stopPrank();

        // Sell USDC, buy USDT -- both allowlisted
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](4);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], SELL, prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);
        tokens[3] = IFolio.TokenRebalanceParams(address(USDT), BUY, FULL_PRICE_RANGE_6, type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        (uint256 nonce, , , , , ) = folio.getRebalance();
        assertEq(nonce, 1, "rebalance should have started");
    }

    // ========== Allowlist Persists Through Enable/Disable ==========

    function test_allowlistPersistsThroughEnableDisable() public {
        address[] memory tokensToAdd = new address[](2);
        tokensToAdd[0] = address(USDC);
        tokensToAdd[1] = address(DAI);

        vm.startPrank(owner);
        folio.addToAllowlist(tokensToAdd);
        folio.setTradeAllowlistEnabled(true);
        assertTrue(folio.isTokenAllowlisted(address(USDC)));
        assertTrue(folio.isTokenAllowlisted(address(DAI)));

        // Disable allowlist
        folio.setTradeAllowlistEnabled(false);

        // Tokens should still be in the allowlist even when disabled
        assertTrue(folio.isTokenAllowlisted(address(USDC)), "USDC should still be in allowlist");
        assertTrue(folio.isTokenAllowlisted(address(DAI)), "DAI should still be in allowlist");
        assertEq(folio.getTokenAllowlist().length, 2, "allowlist should still have 2 tokens");

        // Re-enable and verify enforcement still works
        folio.setTradeAllowlistEnabled(true);
        vm.stopPrank();

        // MEME not allowlisted, non-zero weights should fail
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__TokenNotAllowlisted.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
    }

    // ========== Empty Allowlist with Enabled ==========

    function test_rebalance_emptyAllowlistEnabled_allTokensRejected() public {
        // Enable allowlist without adding any tokens
        vm.prank(owner);
        folio.setTradeAllowlistEnabled(true);

        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], weights[0], prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], weights[1], prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], weights[2], prices[2], type(uint256).max, true);

        // All tokens have non-zero weights but none are allowlisted
        vm.prank(dao);
        vm.expectRevert(IFolio.Folio__TokenNotAllowlisted.selector);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);
    }

    function test_rebalance_emptyAllowlistEnabled_allZeroWeightsSucceeds() public {
        // Enable allowlist without adding any tokens
        vm.prank(owner);
        folio.setTradeAllowlistEnabled(true);

        // All tokens with zero weights (sell all) -- should succeed
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](3);
        tokens[0] = IFolio.TokenRebalanceParams(assets[0], SELL, prices[0], type(uint256).max, true);
        tokens[1] = IFolio.TokenRebalanceParams(assets[1], SELL, prices[1], type(uint256).max, true);
        tokens[2] = IFolio.TokenRebalanceParams(assets[2], SELL, prices[2], type(uint256).max, true);

        vm.prank(dao);
        folio.startRebalance(tokens, limits, AUCTION_LAUNCHER_WINDOW, MAX_TTL);

        (uint256 nonce, , , , , ) = folio.getRebalance();
        assertEq(nonce, 1, "rebalance should have started");
    }

    // ========== Batch Operations ==========

    function test_addAndRemoveBatch() public {
        vm.startPrank(owner);

        // Add all 4 tokens
        address[] memory allTokens = new address[](4);
        allTokens[0] = address(USDC);
        allTokens[1] = address(DAI);
        allTokens[2] = address(MEME);
        allTokens[3] = address(USDT);
        folio.addToAllowlist(allTokens);

        assertEq(folio.getTokenAllowlist().length, 4);
        assertTrue(folio.isTokenAllowlisted(address(USDC)));
        assertTrue(folio.isTokenAllowlisted(address(DAI)));
        assertTrue(folio.isTokenAllowlisted(address(MEME)));
        assertTrue(folio.isTokenAllowlisted(address(USDT)));

        // Remove 2 tokens
        address[] memory toRemove = new address[](2);
        toRemove[0] = address(MEME);
        toRemove[1] = address(USDT);
        folio.removeFromAllowlist(toRemove);

        assertEq(folio.getTokenAllowlist().length, 2);
        assertTrue(folio.isTokenAllowlisted(address(USDC)));
        assertTrue(folio.isTokenAllowlisted(address(DAI)));
        assertFalse(folio.isTokenAllowlisted(address(MEME)));
        assertFalse(folio.isTokenAllowlisted(address(USDT)));

        vm.stopPrank();
    }
}
