// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.25;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library Decimals {
    /// Shift this uint192 left by `decimals` digits, and convert to a uint.
    /// @return x * 10**decimals
    // as-ints: x * 10**(decimals - 18)
    function shiftl(uint256 x, int8 decimals, Math.Rounding rounding) internal pure returns (uint256) {
        // Handle overflow cases
        if (x == 0) return 0; // always computable, no matter what decimals is
        if (decimals <= -42) return (rounding == Math.Rounding.Up ? 1 : 0);
        if (96 <= decimals) revert("uint out of bounds");

        decimals -= 18; // shift so that toUint happens at the same time.

        uint256 coeff = uint256(10 ** abs(int256(decimals)));
        return decimals >= 0 ? x * coeff : divrnd(x, coeff, rounding);
    }

    /// Divide two uints, returning a uint, using rounding mode `rounding`.
    /// @return numerator / divisor
    // as-ints: numerator / divisor
    function divrnd(uint256 numerator, uint256 divisor, Math.Rounding rounding) public pure returns (uint256) {
        uint256 result = numerator / divisor;

        if (rounding == Math.Rounding.Down) return result;

        if (rounding == Math.Rounding.Zero) {
            if (numerator % divisor > (divisor - 1) / 2) {
                result++;
            }
        } else {
            if (numerator % divisor != 0) {
                result++;
            }
        }

        return result;
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
