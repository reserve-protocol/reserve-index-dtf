// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISwap } from "@interfaces/ISwap.sol";

interface ISwapFactory {
    enum SwapKind {
        CowSwap
        // ...
    }
    function createSwaps(SwapKind[] calldata kinds) external returns (ISwap[] memory swaps);
}
