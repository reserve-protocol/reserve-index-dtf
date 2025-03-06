// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { UD60x18, Math } from "@prb/math/src/UD60x18.sol";

library MathLib {
    function pow(uint256 x, uint256 y) external pure returns (uint256 z) {
        return Math.pow(UD60x18.wrap(x), UD60x18.wrap(y)).unwrap();
    }
}
