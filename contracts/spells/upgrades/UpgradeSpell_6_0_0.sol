// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";
import { PROPOSER_ROLE } from "@reserve-protocol/reserve-governor/contracts/utils/Constants.sol";

import { Folio } from "@src/Folio.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { DEFAULT_ADMIN_ROLE, MIN_AUCTION_LENGTH } from "@utils/Constants.sol";
import { Versioned } from "@utils/Versioned.sol";

bytes32 constant VERSION_5_0_0 = keccak256("5.0.0");
bytes32 constant VERSION_6_0_0 = keccak256("6.0.0");
bytes4 constant START_REBALANCE_5_0_0 = 0x207c8eed;
bytes4 constant START_REBALANCE_6_0_0 = 0xc1e54b89;

interface IFolio_5_0_0 {
    function auctionLength() external view returns (uint256);
}

interface ISelectorRegistry_6_0_0 is IOptimisticSelectorRegistry {
    function governor() external view returns (address);
}

interface IOptimisticGovernor_6_0_0 is IReserveOptimisticGovernor {
    function selectorRegistry() external view returns (address);
}

/**
 * @title UpgradeSpell_6_0_0
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Upgrades an idle Folio from 5.0.0 to 6.0.0.
 * @dev Transfer ProxyAdmin ownership to this contract and call cast() atomically from the Folio admin timelock.
 *      For optimistic governance, replace the startRebalance selector before cast() and pass the selector registry.
 *      For legacy governance, pass address(0) as the selector registry.
 */
contract UpgradeSpell_6_0_0 is Versioned {
    error UpgradeSpell__Error(uint256 code);

    function cast(Folio folio, FolioProxyAdmin proxyAdmin, ISelectorRegistry_6_0_0 selectorRegistry) external {
        require(keccak256(bytes(folio.version())) == VERSION_5_0_0, UpgradeSpell__Error(1));
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), UpgradeSpell__Error(2));
        require(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1, UpgradeSpell__Error(3));
        require(folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0) == msg.sender, UpgradeSpell__Error(4));
        require(proxyAdmin.owner() == address(this), UpgradeSpell__Error(5));

        if (address(selectorRegistry) != address(0)) {
            address governor = selectorRegistry.governor();
            IOptimisticGovernor_6_0_0 optimisticGovernor = IOptimisticGovernor_6_0_0(governor);

            require(optimisticGovernor.timelock() == msg.sender, UpgradeSpell__Error(6));
            require(IAccessControl(msg.sender).hasRole(PROPOSER_ROLE, governor), UpgradeSpell__Error(7));
            require(optimisticGovernor.selectorRegistry() == address(selectorRegistry), UpgradeSpell__Error(8));
            require(selectorRegistry.isAllowed(address(folio), START_REBALANCE_6_0_0), UpgradeSpell__Error(9));
            require(!selectorRegistry.isAllowed(address(folio), START_REBALANCE_5_0_0), UpgradeSpell__Error(10));
        }

        require(IFolio_5_0_0(address(folio)).auctionLength() >= MIN_AUCTION_LENGTH, UpgradeSpell__Error(11));

        (bool syncStateChangeActive, bool asyncStateChangeActive) = folio.stateChangeActive();
        require(!syncStateChangeActive && !asyncStateChangeActive, UpgradeSpell__Error(12));

        (, , , , Folio.RebalanceTimestamps memory timestamps, ) = folio.getRebalance();
        require(timestamps.availableUntil <= block.timestamp, UpgradeSpell__Error(13));

        uint256 nextAuctionId = folio.nextAuctionId();
        if (nextAuctionId != 0) {
            (, , uint256 endTime) = folio.auctions(nextAuctionId - 1);
            require(endTime < block.timestamp, UpgradeSpell__Error(14));
        }

        proxyAdmin.upgradeToVersion(address(folio), VERSION_6_0_0, abi.encodeCall(Folio.poke, ()));
        require(keccak256(bytes(folio.version())) == VERSION_6_0_0, UpgradeSpell__Error(15));

        proxyAdmin.transferOwnership(msg.sender);
        require(proxyAdmin.owner() == msg.sender, UpgradeSpell__Error(16));
    }
}
