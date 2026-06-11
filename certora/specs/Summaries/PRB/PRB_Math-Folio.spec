import "../Math.spec";

methods {
    // prb-math uses top-level functions, so we use wildcards
    function _.mulDiv(uint256 x, uint256 y, uint256 denominator) internal => mulDivDownSummary(x,y,denominator) expect uint256;
    function _.mulDiv18(uint256 x, uint256 y) internal => mulDivDownSummary(x,y,10^18) expect uint256;
    
    // SD59x18 operations (signed decimal with 18 decimals)
    function _.mul(Folio.SD59x18 x, Folio.SD59x18 y) internal => mulDivSD59x18Summary(x,y) expect int256;
    function _.div(Folio.SD59x18 x, Folio.SD59x18 y) internal => divSD59x18Summary(x,y) expect int256;
    
    // UD60x18 operations (unsigned decimal with 18 decimals)  
    function _.mul(Folio.UD60x18 x, Folio.UD60x18 y) internal => mulDivUD60x18Summary(x,y) expect uint256;
    function _.div(Folio.UD60x18 x, Folio.UD60x18 y) internal => divUD60x18Summary(x,y) expect uint256;
}

definition min_int256() returns mathint = -1 * 2^255;
definition max_int256() returns mathint = 2^255 - 1;

// SD59x18 multiplication (signed 59.18 fixed point)
function mulDivSD59x18Summary(int256 x, int256 y) returns int256 {
    mathint result;
    result = (x * y) / 10^18;
    // Check for overflow/underflow
    if (result > max_int256() || result < min_int256()) revert();
    return assert_int256(result);
}

// SD59x18 division (signed 59.18 fixed point)
function divSD59x18Summary(int256 x, int256 y) returns int256 {
    mathint result;
    if (y == 0) revert();
    result = (x * 10^18) / y;
    // Check for overflow/underflow
    if (result > max_int256() || result < min_int256()) revert();
    return assert_int256(result);
}

// UD60x18 multiplication (unsigned 60.18 fixed point)
function mulDivUD60x18Summary(uint256 x, uint256 y) returns uint256 {
    mathint result;
    result = (x * y) / 10^18;
    if (result >= 2^256) revert();
    return assert_uint256(result);
}

// UD60x18 division (unsigned 60.18 fixed point)
function divUD60x18Summary(uint256 x, uint256 y) returns uint256 {
    mathint result;
    if (y == 0) revert();
    result = (x * 10^18) / y;
    if (result >= 2^256) revert();
    return assert_uint256(result);
}