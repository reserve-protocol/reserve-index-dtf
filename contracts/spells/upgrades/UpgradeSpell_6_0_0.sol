// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Folio } from "@src/Folio.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { DEFAULT_ADMIN_ROLE } from "@utils/Constants.sol";
import { Versioned } from "@utils/Versioned.sol";

bytes32 constant VERSION_5_0_0 = keccak256("5.0.0");
bytes32 constant VERSION_6_0_0 = keccak256("6.0.0");

/**
 * @title UpgradeSpell_6_0_0
 * @author tbrent
 * @notice Upgrades an idle Folio from 5.0.0 to 6.0.0.
 * @dev Transfer ProxyAdmin ownership to this contract and call cast() atomically from the Folio admin timelock.
 *      Optimistic selector-registry changes must be separate calls in the same standard governance proposal.
 */
contract UpgradeSpell_6_0_0 is Versioned {
    error ActiveAuction();
    error ActiveRebalance();
    error InvalidVersion();
    error NotProxyAdminOwner();
    error StateChangeActive();
    error UnauthorizedCaller();
    error UnexpectedAdmins();
    error UpgradeFailed();

    function cast(Folio folio, FolioProxyAdmin proxyAdmin) external {
        require(keccak256(bytes(folio.version())) == VERSION_5_0_0, InvalidVersion());
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), UnauthorizedCaller());
        require(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1, UnexpectedAdmins());
        require(folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0) == msg.sender, UnexpectedAdmins());
        require(proxyAdmin.owner() == address(this), NotProxyAdminOwner());

        (bool syncStateChangeActive, bool asyncStateChangeActive) = folio.stateChangeActive();
        require(!syncStateChangeActive && !asyncStateChangeActive, StateChangeActive());

        (, , , , Folio.RebalanceTimestamps memory timestamps, ) = folio.getRebalance();
        require(timestamps.availableUntil <= block.timestamp, ActiveRebalance());

        uint256 nextAuctionId = folio.nextAuctionId();
        if (nextAuctionId != 0) {
            (, , uint256 endTime) = folio.auctions(nextAuctionId - 1);
            require(endTime < block.timestamp, ActiveAuction());
        }

        proxyAdmin.upgradeToVersion(address(folio), VERSION_6_0_0, abi.encodeCall(Folio.poke, ()));
        require(keccak256(bytes(folio.version())) == VERSION_6_0_0, UpgradeFailed());

        proxyAdmin.transferOwnership(msg.sender);
        require(proxyAdmin.owner() == msg.sender, UpgradeFailed());
    }
}
