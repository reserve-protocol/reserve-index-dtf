// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISwap } from "@interfaces/ISwap.sol";

interface ISwapFactory {
    event SwapCreated(ISwap indexed swap, SwapKind kind);

    enum SwapKind {
        CowSwap
        // ...
    }
    function createSwap(SwapKind kind) external returns (ISwap _swap);
}
