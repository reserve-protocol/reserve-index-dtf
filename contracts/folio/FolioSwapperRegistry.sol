// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolioSwapperRegistry } from "@interfaces/IFolioSwapperRegistry.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";
import { ISwapper } from "@interfaces/ISwapper.sol";

/**
 * @title FolioSwapperRegistry
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Registry for the latest Swapper
 */
contract FolioSwapperRegistry is IFolioSwapperRegistry {
    IRoleRegistry public immutable roleRegistry;

    address internal swapper;
    mapping(address => bool) public isDeprecated;

    constructor(IRoleRegistry _roleRegistry) {
        require(address(_roleRegistry) != address(0), FolioSwapperRegistry__InvalidRoleRegistry());

        roleRegistry = _roleRegistry;
    }

    function setLatestSwapper(ISwapper _swapper) external {
        require(roleRegistry.isOwner(msg.sender), FolioSwapperRegistry__InvalidCaller());
        require(address(_swapper) != address(0), FolioSwapperRegistry__InvalidSwapper());

        isDeprecated[address(_swapper)] = false;
        swapper = address(_swapper);
        emit SwapperSet(_swapper);
    }

    function deprecateSwapper(ISwapper _swapper) external {
        require(roleRegistry.isOwnerOrEmergencyCouncil(msg.sender), FolioSwapperRegistry__InvalidCaller());
        require(address(_swapper) != address(0), FolioSwapperRegistry__InvalidSwapper());

        isDeprecated[address(_swapper)] = true;
        emit SwapperDeprecated(_swapper);
    }

    /// @dev Warning, can revert if latest swapper has been deprecated
    function getLatestSwapper() external view returns (ISwapper) {
        require(!isDeprecated[swapper], FolioSwapperRegistry__SwapperDeprecated());
        return ISwapper(swapper);
    }
}
