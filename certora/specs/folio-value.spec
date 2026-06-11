import "folio-assumptions.spec";

////////////////////////////////////////////////////////////////////////////
//                               Properties                               //
////////////////////////////////////////////////////////////////////////////


/*
    All rules are passing: https://prover.certora.com/output/17512/78439f0cee004725ad2e1e24ae91f8e9/?anonymousKey=35235616a508c979b9a521a45e0d04e8f8cbe2cb
*/


rule totalValueOfTokenDoesNotDecrease(env e, calldataarg args, method f) 
    filtered { 
        f -> !f.isView &&
            f.selector != sig:removeFromBasket(address).selector &&
            f.selector != sig:bid(uint256,address,address,uint256,uint256,bool,bytes).selector &&
            f.selector != sig:createTrustedFill(uint256,address,address,address,bytes32).selector &&
            f.selector != sig:initialize(IFolio.FolioBasicDetails,IFolio.FolioAdditionalDetails,IFolio.FolioRegistryIndex,IFolio.FolioFlags,address).selector &&
            f.selector != sig:mint(uint256,address,uint256).selector
    } 
{
    require e.msg.sender != currentContract;
    setupAssumptionsWithAuction(e);
    assumeNoTrustedFillers();

    address token;
    require ghostIndexes[to_bytes32(token)] != 0, "the token is in the basket";
    uint256 price;
    uint256 shares_before = totalSupply(e);
    require shares_before > 0, "share value has to be defined";
    
    mathint tokenValue_before = balanceByToken[token][currentContract] * price;
    mathint shareValue_before = tokenValue_before / shares_before;
    
    // Execute function
    f(e, args);
    
    uint256 shares_after = totalSupply(e);
    require shares_after > 0, "share value has to be defined";
    
    mathint tokenValue_after = balanceByToken[token][currentContract] * price;
    mathint shareValue_after = tokenValue_after / shares_after;
    
    assert shareValue_after >= shareValue_before;
}


rule totalValueOfTokenDoesNotDecreaseOnMint() {
    uint256 tokenAmountBefore;
    uint256 tokenAmountAfter;
    uint256 folioSharesBefore;
    require folioSharesBefore > 0, "share value is defined";
    uint256 folioSharesAfter;
    require folioSharesAfter > 0, "proven in shareRatioDoesNotDecreaseOnMintTokenX";

    // Proven in shareRatioDoesNotDecreaseOnMint - for all 3 tokens separately
    require tokenAmountBefore * folioSharesAfter <= tokenAmountAfter * folioSharesBefore;

    uint256 price;

    assert tokenAmountBefore * price / folioSharesBefore <= tokenAmountAfter * price / folioSharesAfter;
}




rule tokenValuesAfterBid(env e) {
    uint256 auctionId;
    _, _, _, auctionId = setupAssumptionsWithAuction(e);
    assumeNoTrustedFillers();
    
    address sellToken;
    require ghostIndexes[to_bytes32(sellToken)] != 0, "sellToken is in the basket";
    address buyToken;
    require ghostIndexes[to_bytes32(buyToken)] != 0, "buyToken is in the basket";
    address otherToken;
    require ghostIndexes[to_bytes32(otherToken)] != 0, "the other token is in the basket";

    require sellToken != buyToken && sellToken != otherToken && buyToken != otherToken, "the three tokens are different";


    uint256 sellBalanceBefore = balanceByToken[sellToken][currentContract];
    uint256 buyBalanceBefore = balanceByToken[buyToken][currentContract];
    uint256 otherBalanceBefore = balanceByToken[otherToken][currentContract];
    
    // Execute bid
    uint256 sellAmount;
    uint256 maxBuyAmount;
    bool withCallback;
    bytes data;
    uint256 bidAmount = bid(e, auctionId, sellToken, buyToken, sellAmount, maxBuyAmount, withCallback, data);
    
    uint256 sellBalanceAfter = balanceByToken[sellToken][currentContract];
    uint256 buyBalanceAfter = balanceByToken[buyToken][currentContract];
    uint256 otherBalanceAfter = balanceByToken[otherToken][currentContract];

    assert sellBalanceAfter == sellBalanceBefore - sellAmount;
    assert buyBalanceAfter == buyBalanceBefore + bidAmount;
    assert otherBalanceAfter == otherBalanceBefore;

    uint256 price = getPrice(e, sellToken, buyToken);

    assert bidAmount == mulDivUpSummary(sellAmount, price, 10^27);
}


rule tokenRanges(env e) {
    uint256 auctionId;
    _, _, _, auctionId = setupAssumptionsWithAuction(e);
    assumeNoTrustedFillers();

    address sellToken;
    require ghostIndexes[to_bytes32(sellToken)] != 0, "sellToken is in the basket";
    address buyToken;
    require ghostIndexes[to_bytes32(buyToken)] != 0, "buyToken is in the basket";

    require sellToken != buyToken, "the two tokens are different";


    bool sellTokenInSurplus = isTokenInSurplus(e,sellToken);
    bool buyTokenInDeficit = isTokenInDeficit(e,buyToken);

    
    // Execute bid
    uint256 sellAmount;
    uint256 maxBuyAmount;
    bool withCallback;
    bytes data;
    bid(e, auctionId, sellToken, buyToken, sellAmount, maxBuyAmount, withCallback, data);


    assert sellTokenInSurplus;
    assert buyTokenInDeficit;
}


rule tokenPrices(env e) {
    uint256 auctionId;
    _, _, _, auctionId = setupAssumptionsWithAuction(e);
    assumeNoTrustedFillers();
    
    address sellToken;
    require ghostIndexes[to_bytes32(sellToken)] != 0, "sellToken is in the basket";
    address buyToken;
    require ghostIndexes[to_bytes32(buyToken)] != 0, "buyToken is in the basket";

    require sellToken != buyToken, "the two tokens are different";

    uint256 sellBalanceBefore = balanceByToken[sellToken][currentContract];
    uint256 buyBalanceBefore = balanceByToken[buyToken][currentContract];
    
    // Execute bid
    uint256 sellAmount;
    uint256 maxBuyAmount;
    bool withCallback;
    bytes data;
    bid(e, auctionId, sellToken, buyToken, sellAmount, maxBuyAmount, withCallback, data);
    
    uint256 sellPrice = currentContract.auctions[auctionId].prices[sellToken].low;
    uint256 buyPrice = currentContract.auctions[auctionId].prices[buyToken].high;

    uint256 price = getPrice(e, sellToken, buyToken);

    assert sellPrice > 0;
    assert buyPrice > 0;
    assert price >= mulDivUpSummary(sellPrice, 10^27, buyPrice);
}



rule valueCalculation() {
    uint256 sellAmount;
    uint256 sellPrice;
    uint256 buyPrice;
    uint256 price;
    // tokenPrices
    require sellPrice > 0;
    require buyPrice > 0;
    require price >= mulDivUpSummary(sellPrice, 10^27, buyPrice);

    // tokenValuesAfterBid
    uint256 bidAmount = mulDivUpSummary(sellAmount, price, 10^27);

    assert sellAmount * sellPrice <= bidAmount * buyPrice;


    uint256 otherPrice;

    uint256 sellBalanceBefore;
    uint256 sellBalanceAfter;
    uint256 buyBalanceBefore;
    uint256 buyBalanceAfter;
    uint256 otherBalanceBefore;
    uint256 otherBalanceAfter;

    // tokenValuesAfterBid
    require sellBalanceAfter == sellBalanceBefore - sellAmount;
    require buyBalanceAfter == buyBalanceBefore + bidAmount;
    require otherBalanceAfter == otherBalanceBefore;

    // Define value by token
    mathint sellTokenValueBefore = sellBalanceBefore * sellPrice;
    mathint sellTokenValueAfter = sellBalanceAfter * sellPrice;

    mathint buyTokenValueBefore = buyBalanceBefore * buyPrice;
    mathint buyTokenValueAfter = buyBalanceAfter * buyPrice;

    mathint otherTokenValueBefore = otherBalanceBefore * otherPrice;
    mathint otherTokenValueAfter = otherBalanceAfter * otherPrice;

    assert sellTokenValueBefore + buyTokenValueBefore + otherTokenValueBefore <= sellTokenValueAfter + buyTokenValueAfter + otherTokenValueAfter;
}





rule shareRatioDoesNotDecreaseOnMintToken1(env e, method f, calldataarg args) 
{
    
    address token1;
    uint256 id;
    token1, _, _, id = setupAssumptionsWithAuction(e);
    assumeNoTrustedFillers();
    
    require e.msg.sender != currentContract;

    uint256 tokenAmountBefore = getBalanceOfToken(token1);
    uint256 folioSharesBefore = totalSupply(e);

    mint(e,args);

    uint256 tokenAmountAfter = getBalanceOfToken(token1);
    uint256 folioSharesAfter = totalSupply(e);

    assert folioSharesBefore <= folioSharesAfter;
    assert tokenAmountBefore * folioSharesAfter <= tokenAmountAfter * folioSharesBefore;
}


rule shareRatioDoesNotDecreaseOnMintToken2(env e, method f, calldataarg args) 
{
    address token2;
    uint256 id;
    _, token2, _, id = setupAssumptionsWithAuction(e);
    assumeNoTrustedFillers();
    
    require e.msg.sender != currentContract;

    uint256 tokenAmountBefore = getBalanceOfToken(token2);
    uint256 folioSharesBefore = totalSupply(e);

    mint(e,args);

    uint256 tokenAmountAfter = getBalanceOfToken(token2);
    uint256 folioSharesAfter = totalSupply(e);

    assert folioSharesBefore <= folioSharesAfter;
    assert tokenAmountBefore * folioSharesAfter <= tokenAmountAfter * folioSharesBefore;
}


rule shareRatioDoesNotDecreaseOnMintToken3(env e, method f, calldataarg args) 
{
    address token3;
    uint256 id;
    _, _, token3, id = setupAssumptionsWithAuction(e);
    assumeNoTrustedFillers();
    
    require e.msg.sender != currentContract;

    uint256 tokenAmountBefore = getBalanceOfToken(token3);
    uint256 folioSharesBefore = totalSupply(e);

    mint(e,args);

    uint256 tokenAmountAfter = getBalanceOfToken(token3);
    uint256 folioSharesAfter = totalSupply(e);

    assert folioSharesBefore <= folioSharesAfter;
    assert tokenAmountBefore * folioSharesAfter <= tokenAmountAfter * folioSharesBefore;
}