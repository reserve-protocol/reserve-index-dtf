// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { UD60x18, pow as UD_pow, powu as UD_powu, ln as UD_ln } from "@prb/math/src/UD60x18.sol";
import { SD59x18, intoUint256, exp as SD_exp } from "@prb/math/src/SD59x18.sol";

library MathLib {
    /// @param x 18 decimal fixed point
    /// @param y 18 decimal fixed point
    /// @return z 18 decimal fixed point
    function pow(uint256 x, uint256 y) external pure returns (uint256 z) {
        return UD_pow(UD60x18.wrap(x), UD60x18.wrap(y)).unwrap();
    }

    /// @param x 18 decimal fixed point
    /// @param y whole number exponent
    /// @return z 18 decimal fixed point
    function powu(uint256 x, uint256 y) external pure returns (uint256 z) {
        return UD_powu(UD60x18.wrap(x), y).unwrap();
    }

    // ==== Internal ====

    /// @param x 18 decimal fixed point
    /// @return z 18 decimal fixed point
    function ln(uint256 x) internal pure returns (uint256 z) {
        return UD_ln(UD60x18.wrap(x)).unwrap();
    }

    /// @param x 18 decimal fixed point
    /// @return z 18 decimal fixed point
    function exp(int256 x) internal pure returns (uint256 z) {
        return intoUint256(SD_exp(SD59x18.wrap(x)));
    }
}
