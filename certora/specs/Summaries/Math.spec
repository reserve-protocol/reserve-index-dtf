function mulDivDownSummary(uint256 x, uint256 y, uint256 denominator) returns uint256 {
    mathint result;
    if (denominator == 0) revert();
    result = x * y / denominator;
    if (result >= 2^256) revert();
    return assert_uint256(result);
}

function mulDivUpSummary(uint256 x, uint256 y, uint256 denominator) returns uint256 {
    mathint result;
    if (denominator == 0) revert();
    result = (x * y + denominator - 1) / denominator;
    if (result >= 2^256) revert();
    return assert_uint256(result);
}

function averageSummary(uint256 a, uint256 b) returns uint256 {
    return require_uint256((a+b)/2);
}

function sqrtSummary(uint256 x) returns uint256 {
    mathint result;
    // not sure if this is the best way
    require result * result <= x && x < (result + 1) * (result + 1);
    return assert_uint256(result);
}