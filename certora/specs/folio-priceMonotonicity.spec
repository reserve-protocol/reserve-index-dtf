import "summaries-Folio.spec";

using InterpolatePriceHarness as priceHarness;

methods {
    function _.exp(int256 x) internal => expCVL(x) expect (uint256);
    function _.ln(uint256 x) internal => lnCVL(x) expect (uint256);

    function InterpolatePriceHarness.interpolatePrice(uint256, uint256, uint256, uint256) external returns (uint256) envfree;
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
//                     Check price monotonicity                           //
////////////////////////////////////////////////////////////////////////////


rule priceMonotonicity(env e1, env e2, address sellToken, address buyToken) {

    uint256 id = require_uint256(currentContract.nextAuctionId - 1);
    require currentContract.auctions[id].prices[buyToken].low <= currentContract.auctions[id].prices[buyToken].high;
    require currentContract.auctions[id].prices[buyToken].high <= 10^45;
    require currentContract.auctions[id].prices[buyToken].low * 100 >= currentContract.auctions[id].prices[buyToken].high;
    require currentContract.auctions[id].prices[sellToken].low <= currentContract.auctions[id].prices[sellToken].high;
    require currentContract.auctions[id].prices[sellToken].low * 100 >= currentContract.auctions[id].prices[sellToken].high;
    require currentContract.auctions[id].prices[sellToken].high <= 10^45;

    require currentContract.auctions[id].endTime - currentContract.auctions[id].startTime <= 6048000;

    require e1.block.timestamp <= e2.block.timestamp;
    require e1.block.timestamp > currentContract.auctions[id].startTime, "we assume nondeterministic ln and exp, we cannot compare result to the exact value we get at startTime";

    uint256 price1 = getPrice(e1,sellToken,buyToken);
    uint256 price2 = getPrice(e2,sellToken,buyToken);

    assert price1 >= price2;
}

rule priceMonotonicityOfInterpolatePrice(env e) {
    uint256 startPrice;
    uint256 endPrice;
    require startPrice > endPrice;
    require startPrice < 20000 * endPrice, "price.low >= 100 * price.high";
    uint256 elapsed1;
    uint256 elapsed2;
    uint256 auctionLength;

    // Note that here we allow the elapsed1 == 0;
    require elapsed1 <= elapsed2;
    require elapsed2 <= auctionLength;
    require auctionLength <= 6048000, "overapproximation - time limit for auction is 7 days";

    assert priceHarness.interpolatePrice(startPrice, endPrice, elapsed1, auctionLength) >= priceHarness.interpolatePrice(startPrice, endPrice, elapsed2, auctionLength);
}