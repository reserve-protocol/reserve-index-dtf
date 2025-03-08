// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISwapper } from "@interfaces/ISwapper.sol";

interface IFolioSwapperRegistry {
    error FolioSwapperRegistry__SwapperDeprecated();
    error FolioSwapperRegistry__InvalidRoleRegistry();
    error FolioSwapperRegistry__InvalidSwapper();
    error FolioSwapperRegistry__InvalidCaller();

    event SwapperSet(ISwapper swapper);
    event SwapperDeprecated(ISwapper swapper);

    function setLatestSwapper(ISwapper _swapper) external;

    function deprecateSwapper(ISwapper _swapper) external;

    /// @dev Can revert
    function getLatestSwapper() external view returns (ISwapper);
    function isDeprecated(address _swapper) external view returns (bool);
}
