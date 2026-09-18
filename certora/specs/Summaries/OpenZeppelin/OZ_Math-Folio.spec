import "../Math.spec";

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256) => mulDivDownSummary(x,y,denominator);
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) internal returns (uint256) => mulDivDirectionalSummary(x, y, denominator, rounding);
    function Math.average(uint256 a, uint256 b) internal returns (uint256) => averageSummary(a,b);
    function Math.max(uint256 a, uint256 b) internal returns (uint256) => maxSummary(a, b);
    function Math.min(uint256 a, uint256 b) internal returns (uint256) => minSummary(a, b);
}


function maxSummary(uint256 a, uint256 b) returns uint256 {
    return a > b ? a : b;
}

function minSummary(uint256 a, uint256 b) returns uint256 {
    return a < b ? a : b;
}

function mulDivDirectionalSummary(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) returns uint256 {
    // OZ v<5 used `Up`, v>=5 uses `Ceil`.
    if (rounding == Math.Rounding.Ceil) {
        return mulDivUpSummary(x, y, denominator);
    } else {
        return mulDivDownSummary(x, y, denominator);
    }
}

