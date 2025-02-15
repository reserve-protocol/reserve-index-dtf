// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { ISwap } from "@interfaces/ISwap.sol";
import { ISwapFactory } from "@interfaces/ISwapFactory.sol";
import { CowSwapSwap } from "./CowSwapSwap.sol";

contract SwapFactory is ISwapFactory {
    using Clones for address;

    address public immutable cowSwapSwapImplementation;

    constructor() {
        cowSwapSwapImplementation = address(new CowSwapSwap());
    }

    function createSwap(SwapKind kind) external returns (ISwap swap) {
        if (kind == SwapKind.CowSwap) {
            swap = ISwap(cowSwapSwapImplementation.clone());
            emit SwapCreated(ISwap(address(swap)), kind);
        }
    }
}
