methods {
    function interpolatePrice(uint256, uint256, uint256, uint256) external returns (uint256) envfree;
    function _.ln(uint256 x) internal => lnCVL(x) expect (uint256);

    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256) => mulDivDownSummary(x,y,denominator);
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) internal returns (uint256) => mulDivDirectionalSummary(x, y, denominator, rounding);
}

function mulDivDirectionalSummary(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) returns uint256 {
    if (rounding == Math.Rounding.Ceil) {
        return mulDivUpSummary(x, y, denominator);
    } else {
        return mulDivDownSummary(x, y, denominator);
    }
}

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

////////////////////////////////////////////////////////////////////////////
//                              GHOSTS                                    //
////////////////////////////////////////////////////////////////////////////

ghost lnCVL(uint256) returns uint256 {
    axiom forall uint256 x . x < 20000000000000000000000 => lnCVL(x) <= 100000000000000000000000;
}

ghost expCVL(mathint) returns uint256
{
    axiom forall mathint x. forall mathint y . x <= y => expCVL(x) <= expCVL(y);
    // axiom expCVL(0) == 1000000000000000000;
    // axiom forall uint256 x . expCVL(x) >= x;
}


////////////////////////////////////////////////////////////////////////////
//                 Check the value of price at startTime                  //
////////////////////////////////////////////////////////////////////////////

rule priceMonotonicityAtStart(env e) {
    uint256 startPrice;
    uint256 endPrice;
    uint256 elapsed = 0;
    uint256 auctionLength;
    assert interpolatePrice(startPrice, endPrice, elapsed,auctionLength) == startPrice;
}