// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { ISwap } from "@interfaces/ISwap.sol";
import { ISwapFactory } from "@interfaces/ISwapFactory.sol";
import { CowSwapSwap } from "./CowSwapSwap.sol";

import { Versioned } from "@utils/Versioned.sol";

contract SwapFactory is ISwapFactory, Versioned {
    using Clones for address;

    address public immutable cowSwapSwapImplementation;

    constructor() {
        cowSwapSwapImplementation = address(new CowSwapSwap());
    }

    function createSwap(bytes32 deploymentSalt) external returns (ISwap swap) {
        swap = ISwap(cowSwapSwapImplementation.cloneDeterministic(deploymentSalt));
        emit SwapCreated(ISwap(address(swap)));
    }
}
