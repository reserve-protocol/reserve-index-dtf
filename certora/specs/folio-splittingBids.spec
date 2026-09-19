import "folio-assumptions.spec";


////////////////////////////////////////////////////////////////////////////
//                               Properties                               //
////////////////////////////////////////////////////////////////////////////

rule bidResult(env e) {
    uint256 id;
    _,_,_, id = setupAssumptionsWithAuction(e);
    assumeNoTrustedFillers();

    address sellToken;
    address buyToken;
    address otherToken;
    require otherToken != sellToken && otherToken != buyToken;
    uint256 sellAmount;
    uint256 maxBuyAmount;
    bool withCallback;
    bytes data;

    uint256 sellBefore = balanceByToken[sellToken][currentContract];
    uint256 buyBefore = balanceByToken[buyToken][currentContract];
    uint256 otherBefore = balanceByToken[otherToken][currentContract];

    uint256 bidAmount = bid(e,id, sellToken, buyToken,sellAmount,maxBuyAmount,withCallback,data);
   
    uint256 sellAfter = balanceByToken[sellToken][currentContract];
    uint256 buyAfter = balanceByToken[buyToken][currentContract];
    uint256 otherAfter = balanceByToken[otherToken][currentContract];

    uint256 price = getPrice(e,sellToken,buyToken);

    assert bidAmount == mulDivUpSummary(sellAmount, price, 10^27);
    assert sellBefore == sellAfter + sellAmount;
    assert buyBefore + bidAmount == buyAfter;
    assert otherBefore == otherAfter;
}


rule splitCalculation() {
    uint256 totalSell;
    uint256 partialSell1;
    uint256 partialSell2;
    require partialSell1 + partialSell2 == totalSell, "rule requirement";

    uint256 price;

    uint256 totalBid = mulDivUpSummary(totalSell, price, 10^27);
    uint256 partialBid1 = mulDivUpSummary(partialSell1, price, 10^27);
    uint256 partialBid2 = mulDivUpSummary(partialSell2, price, 10^27);

    // Since we always sell the sellAmount exactly, we do not need to check the sellToken.
    assert totalBid <= partialBid1 + partialBid2;
    assert totalBid + 1 >= partialBid1 + partialBid2;
}