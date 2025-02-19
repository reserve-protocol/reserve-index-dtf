// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { ISwap } from "@interfaces/ISwap.sol";
import { ISwapper } from "@interfaces/ISwapper.sol";
import { CowSwapSwap } from "./CowSwapSwap.sol";

import { Versioned } from "@utils/Versioned.sol";

/**
 * @title Swapper
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Swapper is a factory for creating new swaps
 */
contract Swapper is ISwapper, Versioned {
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
