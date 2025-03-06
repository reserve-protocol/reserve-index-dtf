// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { UD60x18, pow as UD_pow } from "@prb/math/src/UD60x18.sol";
import { SD59x18, intoUint256, exp as SD_exp } from "@prb/math/src/SD59x18.sol";

library MathLib {
    function pow(uint256 x, uint256 y) external pure returns (uint256 z) {
        return UD_pow(UD60x18.wrap(x), UD60x18.wrap(y)).unwrap();
    }

    function exp(int256 x) external pure returns (uint256 z) {
        return intoUint256(SD_exp(SD59x18.wrap(x)));
    }
}
