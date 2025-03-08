// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISwap } from "@interfaces/ISwap.sol";

interface ISwapper {
    event SwapCreated(ISwap indexed swap);

    function createSwap(bytes32 deploymentSalt) external returns (ISwap _swap);
}
