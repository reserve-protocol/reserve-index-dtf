// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolioDAOSwapperRegistry } from "@interfaces/IFolioDAOSwapperRegistry.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";
import { ISwapper } from "@interfaces/ISwapper.sol";

/**
 * @title FolioDAOSwapperRegistry
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Registry for the latest Swapper
 */
contract FolioDAOSwapperRegistry is IFolioDAOSwapperRegistry {
    IRoleRegistry public immutable roleRegistry;

    address internal swapper;
    mapping(address => bool) public isDeprecated;

    constructor(IRoleRegistry _roleRegistry) {
        require(address(_roleRegistry) != address(0), FolioDAOSwapperRegistry__InvalidRoleRegistry());

        roleRegistry = _roleRegistry;
    }

    function setLatestSwapper(ISwapper _swapper) external {
        require(roleRegistry.isOwner(msg.sender), FolioDAOSwapperRegistry__InvalidCaller());
        require(address(_swapper) != address(0), FolioDAOSwapperRegistry__InvalidSwapper());

        isDeprecated[address(_swapper)] = false;
        swapper = address(_swapper);
        emit SwapperSet(_swapper);
    }

    function deprecateSwapper(ISwapper _swapper) external {
        require(roleRegistry.isOwnerOrEmergencyCouncil(msg.sender), FolioDAOSwapperRegistry__InvalidCaller());
        require(address(_swapper) != address(0), FolioDAOSwapperRegistry__InvalidSwapper());

        isDeprecated[address(_swapper)] = true;
        emit SwapperDeprecated(_swapper);
    }

    function getLatestSwapper() external view returns (ISwapper) {
        require(!isDeprecated[swapper], FolioDAOSwapperRegistry__SwapperDeprecated());
        return ISwapper(swapper);
    }
}
