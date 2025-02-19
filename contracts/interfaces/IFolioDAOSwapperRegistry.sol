// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISwapper } from "@interfaces/ISwapper.sol";

interface IFolioDAOSwapperRegistry {
    error FolioDAOSwapperRegistry__SwapperDeprecated();
    error FolioDAOSwapperRegistry__InvalidRoleRegistry();
    error FolioDAOSwapperRegistry__InvalidSwapper();
    error FolioDAOSwapperRegistry__InvalidCaller();

    event SwapperSet(ISwapper swapper);
    event SwapperDeprecated(ISwapper swapper);

    function setLatestSwapper(ISwapper _swapper) external;

    function deprecateSwapper(ISwapper _swapper) external;

    /// @dev Can revert
    function getLatestSwapper() external view returns (ISwapper);
    function isDeprecated(address _swapper) external view returns (bool);
}
