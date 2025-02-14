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

    function createSwaps(SwapKind[] calldata kinds) external returns (ISwap[] memory swaps) {
        uint256 len = kinds.length;
        swaps = new ISwap[](len);

        for (uint256 i; i < len; i++) {
            if (kinds[i] == SwapKind.CowSwap) {
                swaps[i] = ISwap(cowSwapSwapImplementation.clone());
            }
        }
    }
}
