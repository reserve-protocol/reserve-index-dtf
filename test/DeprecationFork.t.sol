// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Folio } from "@src/Folio.sol";

import { BaseDeprecationForkTest, DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER, AUCTION_LAUNCHER } from "./base/BaseDeprecationForkTest.sol";

/**
 * @notice Direct simulation of the deprecation steps, pranking as the owner timelock.
 * @dev Regression coverage for the DTFs already deprecated onchain, pinned to blocks before their
 *      proposals executed. New DTFs should be covered by DeprecationJsonFork (before submission) and
 *      DeprecationProposalFork (once queued) instead, since those run the real proposal payload.
 */
abstract contract DeprecationForkTest is BaseDeprecationForkTest {
    DTFConfig[] internal configs;

    function _addConfig(
        string memory symbol,
        address folio,
        address ownerTimelock,
        address tradingTimelock,
        address[] memory auctionLaunchers,
        address proxyAdmin,
        address stakingVault
    ) internal {
        configs.push(
            DTFConfig({
                symbol: symbol,
                folio: folio,
                ownerTimelock: ownerTimelock,
                tradingTimelock: tradingTimelock,
                auctionLaunchers: auctionLaunchers,
                proxyAdmin: proxyAdmin,
                stakingVault: stakingVault
            })
        );
    }

    /// @dev Deprecate folio + revoke all roles
    function test_deprecation_fork() public {
        for (uint256 i; i < configs.length; i++) {
            _deprecateAsTimelock(configs[i]);
        }
    }

    /// @dev Renounce ProxyAdmin ownership
    function test_renounceProxyAdmin_fork() public {
        for (uint256 i; i < configs.length; i++) {
            _renounceProxyAdminAsTimelock(configs[i]);
        }
    }

    /// @dev Full flow: deprecate, verify redeem/mint/unstake, renounce ProxyAdmin
    function test_fullDeprecation_fork() public {
        for (uint256 i; i < configs.length; i++) {
            _deprecateAsTimelock(configs[i]);
            _assertRedemptionOnlyMode(configs[i]);
            _renounceProxyAdminAsTimelock(configs[i]);
        }
    }

    function _deprecateAsTimelock(DTFConfig memory cfg) internal {
        _assertLiveAndGoverned(cfg);

        vm.startPrank(cfg.ownerTimelock);

        // 1. deprecateFolio()
        Folio(cfg.folio).deprecateFolio();

        // 2. Revoke REBALANCE_MANAGER
        if (cfg.tradingTimelock != address(0)) {
            IAccessControlEnumerable(cfg.folio).revokeRole(REBALANCE_MANAGER, cfg.tradingTimelock);
        }

        // 3. Revoke AUCTION_LAUNCHER(s)
        for (uint256 i; i < cfg.auctionLaunchers.length; i++) {
            IAccessControlEnumerable(cfg.folio).revokeRole(AUCTION_LAUNCHER, cfg.auctionLaunchers[i]);
        }

        // 4. Revoke DEFAULT_ADMIN_ROLE (last)
        IAccessControlEnumerable(cfg.folio).revokeRole(DEFAULT_ADMIN_ROLE, cfg.ownerTimelock);

        vm.stopPrank();

        _assertDeprecated(cfg);
    }

    function _renounceProxyAdminAsTimelock(DTFConfig memory cfg) internal {
        _assertProxyAdminOwned(cfg);

        vm.prank(cfg.ownerTimelock);
        Ownable(cfg.proxyAdmin).renounceOwnership();

        _assertProxyAdminRenounced(cfg);
    }
}

contract DeprecationForkTest_Mainnet is DeprecationForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), 24675000);

        // mvRWA
        address[] memory mvRWA_launchers = new address[](3);
        mvRWA_launchers[0] = 0x6293e97900aA987Cf3Cbd419e0D5Ba43ebfA91c1;
        mvRWA_launchers[1] = 0xC6625129C9df3314a4dd604845488f4bA62F9dB8;
        mvRWA_launchers[2] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;
        _addConfig(
            "mvRWA",
            0xA5cdea03B11042fc10B52aF9eCa48bb17A2107d2,
            0x02188526Dd0021F8032868552d2Ea8529d3A4E53,
            0xF156F05d8eB854926f08983F98bD8Ac27c2f18c4,
            mvRWA_launchers,
            0x019318674560C233893aA31Bc0A380dc71dc2dDf,
            0xa2DeA781F351C9Cb831CB1E6c1A687994E04e8aF
        );

        // mvDEFI
        address[] memory mvDEFI_launchers = new address[](3);
        mvDEFI_launchers[0] = 0x6293e97900aA987Cf3Cbd419e0D5Ba43ebfA91c1;
        mvDEFI_launchers[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        mvDEFI_launchers[2] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;
        _addConfig(
            "mvDEFI",
            0x20d81101D254729a6E689418526bE31e2c544290,
            0x9f4D7074Fe0B9717030E5763e4155Cc75b36380D,
            0x9C2c381588Db0248103ea239044a3Ea60F29B346,
            mvDEFI_launchers,
            0x3927882f047944A9c561F29E204C370Dd84852Fd,
            0xa2DeA781F351C9Cb831CB1E6c1A687994E04e8aF
        );
    }
}

contract DeprecationForkTest_Base is DeprecationForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_BASE", string("base")), 30000000);

        // AI
        address[] memory AI_launchers = new address[](3);
        AI_launchers[0] = 0x5edB66B4c01355B07dF3Ea9e4c2508e4Cc542c6a;
        AI_launchers[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        AI_launchers[2] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;
        _addConfig(
            "AI",
            0xfe45EDa533e97198d9f3dEEDA9aE6c147141f6F9,
            0x1b0545eF805841b7ABef6b5C3a9458772476282e,
            0xB72e489124f1F75E9Afa4f54cd348C191F84d5dD,
            AI_launchers,
            0x456219b7897384217ca224f735DBbC30c395C87F,
            0x2e8520E69b05d05152D23A0556F845d9DB8486AC
        );

        // VTF
        address[] memory VTF_launchers = new address[](3);
        VTF_launchers[0] = 0x93db2e90F8B2b073010B425f9350202330bd923E;
        VTF_launchers[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        VTF_launchers[2] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;
        _addConfig(
            "VTF",
            0x47686106181b3CEfe4eAf94C4c10b48Ac750370b,
            0xc290B859F4f6F0644600DD18D53822bCF95D2602,
            0xCcB16eDde81843E42f3C39AB70598671Eb668bB0,
            VTF_launchers,
            0x7C1fAFfc7F3a52aa9Dbd265E5709202eeA3A8A48,
            0x3305C5BD8Da08Bd6982dD40BE3eECC7b2433e5c3
        );

        // MVDA25
        address[] memory MVDA25_launchers = new address[](3);
        MVDA25_launchers[0] = 0xD8B0F4e54a8dac04E0A57392f5A630cEdb99C940;
        MVDA25_launchers[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        MVDA25_launchers[2] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;
        _addConfig(
            "MVDA25",
            0xD600e748C17Ca237Fcb5967Fa13d688AFf17Be78,
            0xb396e2beC0e914b8A5ef9C1ED748e8E6Be2af135,
            0x364768C014b312b5ff92Ce5D878393F15de3D484,
            MVDA25_launchers,
            0xb467947f35697FadB46D10f36546E99A02088305,
            0x3D72D6E8a5829d02F0153dbBFE71b8D4f5C3B45D
        );
    }
}
