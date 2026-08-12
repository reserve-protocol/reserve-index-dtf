// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseDeprecationForkTest } from "./BaseDeprecationForkTest.sol";

/**
 * @title PendingDeprecations
 * @notice Onchain config for the DTFs queued up for deprecation, so the suites that cover them before and
 *         after submission read from one place.
 */
abstract contract PendingDeprecations is BaseDeprecationForkTest {
    /// @dev BED and SMEL share this vlRSR staking vault, which is also the governance voting token
    address internal constant VLRSR_STEAKHOUSE = 0x5CdE24d90f9Fe1C1893dD30Ca74F99265b46818F;

    /// @dev Both DTFs use the same three auction launchers
    function _mainnetLaunchers() internal pure returns (address[] memory launchers) {
        launchers = new address[](3);
        launchers[0] = 0x280730d9277EF586d58dB74c277Aa710ca8F87C9;
        launchers[1] = 0xC6625129C9df3314a4dd604845488f4bA62F9dB8;
        launchers[2] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;
    }

    function _bed() internal pure returns (PendingDTF memory) {
        return
            PendingDTF({
                cfg: DTFConfig({
                    symbol: "BED",
                    folio: 0x4E3B170DcBe704b248df5f56D488114acE01B1C5,
                    ownerTimelock: 0x6B45fe3F4464477f657702b8e942b71C3bA83944,
                    tradingTimelock: 0x8E530CD0C47d515558229AAE193DD119cc791A40,
                    auctionLaunchers: _mainnetLaunchers(),
                    proxyAdmin: 0xEAa356F6CD6b3fd15B47838d03cF34fa79F7c712,
                    stakingVault: VLRSR_STEAKHOUSE
                }),
                governor: 0xFaD4823Ae478637fD8FfdafB6c912f63c8cd1Dd7,
                jsonPath: "script/deprecation/proposals/deprecate-BED.json"
            });
    }

    function _smel() internal pure returns (PendingDTF memory) {
        return
            PendingDTF({
                cfg: DTFConfig({
                    symbol: "SMEL",
                    folio: 0xF91384484F4717314798E8975BCd904A35fc2BF1,
                    ownerTimelock: 0x476aE35B6dEccda7969F105e983a916BCc12C31A,
                    tradingTimelock: 0x395417220aE7447D19752f38327B96fAF52e1911,
                    auctionLaunchers: _mainnetLaunchers(),
                    proxyAdmin: 0xDd885B0F2f97703B94d2790320b30017a17768BF,
                    stakingVault: VLRSR_STEAKHOUSE
                }),
                governor: 0x622c0b5aD82a2A47F330D4a2061a0e3562F583b0,
                jsonPath: "script/deprecation/proposals/deprecate-SMEL.json"
            });
    }
}
