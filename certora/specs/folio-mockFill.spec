import "folio-assumptions.spec";

using MockTrustedFiller as MockTrustedFiller;

methods {

    function MockTrustedFiller.getFillerAddress() external returns (address) envfree;
    function MockTrustedFiller.sellToken() external returns (address) envfree;
    function MockTrustedFiller.buyToken() external returns (address) envfree;
    function MockTrustedFiller.sellAmount() external returns (uint256) envfree;
    function MockTrustedFiller.minBuyAmount() external returns (uint256) envfree;
    function MockTrustedFiller.price() external returns (uint256) envfree;
    function closeFill() external;

    function TrustedFillerRegistry.createTrustedFiller(address, address, bytes32) external returns (address) => getFillerAddressCVL();
}


function assumeNoTrustedFiller(env e) {
    address filler = MockTrustedFiller.getFillerAddress();
    require forall address token . balanceByToken[token][filler] == 0;
}

function getFillerAddressCVL() returns (address) {
    return MockTrustedFiller.getFillerAddress();
}

////////////////////////////////////////////////////////////////////////////
//                   Checks that mock works as expected                   //
////////////////////////////////////////////////////////////////////////////

rule createTrustedFillRemovesTokens(env e) {
    uint256 id;
    _,_,_,id = setupAssumptionsWithAuction(e);
    address targetFiller;
    address fillerAddress;
    bytes32 salt;

    assumeNoTrustedFiller(e);

    address sellToken; 
    require ghostIndexes[to_bytes32(sellToken)] != 0;
    address buyToken;
    require ghostIndexes[to_bytes32(buyToken)] != 0;
    address otherToken;
    require otherToken != sellToken && otherToken != buyToken;
    
    uint256 balanceBefore1 = balanceByToken[sellToken][currentContract];
    uint256 balanceBefore2 = balanceByToken[buyToken][currentContract];
    uint256 balanceBefore3 = balanceByToken[otherToken][currentContract];

    fillerAddress = createTrustedFill(e, id, sellToken, buyToken, targetFiller, salt);

    uint256 balanceAfter1 = balanceByToken[sellToken][currentContract];
    uint256 balanceAfter2 = balanceByToken[buyToken][currentContract];
    uint256 balanceAfter3 = balanceByToken[otherToken][currentContract];

    assert buyToken != sellToken;

    assert balanceBefore1 >= balanceAfter1;
    assert balanceBefore2 == balanceAfter2;
    assert balanceBefore3 == balanceAfter3;
}

rule closeTrustedFillRescuesTokens(env e) {
    address token1;
    address token2;
    address token3;
    uint256 id;
    _,_,_,id = setupAssumptionsWithAuction(e);

    address filler = MockTrustedFiller.getFillerAddress();

    address sellToken = filler.sellToken(e); 
    require ghostIndexes[to_bytes32(sellToken)] != 0;
    address buyToken = filler.buyToken(e);
    require ghostIndexes[to_bytes32(buyToken)] != 0;
    address otherToken;
    require otherToken != sellToken && otherToken != buyToken;


    uint256 sellTokenBefore = balanceByToken[sellToken][currentContract];
    uint256 buyTokenBefore = balanceByToken[buyToken][currentContract];
    uint256 otherTokenBefore = balanceByToken[otherToken][currentContract];

    uint256 sellTokenInFill = balanceByToken[sellToken][filler];
    uint256 buyTokenInFill = balanceByToken[buyToken][filler];

    closeFill(e);

    assert balanceByToken[sellToken][currentContract] == sellTokenBefore + sellTokenInFill;
    assert balanceByToken[buyToken][currentContract] == buyTokenBefore + buyTokenInFill;
    assert balanceByToken[otherToken][currentContract] == otherTokenBefore;
}


////////////////////////////////////////////////////////////////////////////
//                               Properties                               //
////////////////////////////////////////////////////////////////////////////

rule buyTokenDifferenceCap(env e) {
    uint256 id;
    _, _, _, id = setupAssumptionsWithAuction(e);

    address sellToken; 
    require ghostIndexes[to_bytes32(sellToken)] != 0;
    address buyToken;
    require ghostIndexes[to_bytes32(buyToken)] != 0;
    address otherToken;
    require otherToken != sellToken && otherToken != buyToken;

    uint256 sellAmount;
    uint256 maxBuyAmount;
    bool withCallback;
    bytes data;

    address targetFiller;
    bytes32 salt;

    address filler = MockTrustedFiller.getFillerAddress();

    require balanceByToken[sellToken][filler] == 0;
    require balanceByToken[buyToken][filler] == 0;
    require balanceByToken[otherToken][filler] == 0;


    // BID FLOW
    storage initialStorage = lastStorage;
    uint256 buyTokenViaBid = bid(e,id, sellToken, buyToken,sellAmount,maxBuyAmount,withCallback,data);

    uint256 buyBalanceAfterBid = balanceByToken[buyToken][currentContract];

    // RESET STORAGE AND DO A TRUSTED FILL FLOW
    address trustedFiller = createTrustedFill(e, id, sellToken, buyToken, targetFiller, salt) at initialStorage;

    uint256 bigSellAmount = MockTrustedFiller.sellAmount;
    uint256 bigBuyAmount = MockTrustedFiller.minBuyAmount;
    uint256 fillerPrice = MockTrustedFiller.price;

    uint256 buyTokenViaFill = MockTrustedFiller.exchange(e,sellAmount);
    closeFill(e);

    uint256 buyBalanceAfterFill = balanceByToken[buyToken][currentContract];


    uint256 price = getPrice(e, sellToken, buyToken);

    assert buyTokenViaBid == mulDivUpSummary(sellAmount, price, 10^27);
    assert bigBuyAmount == mulDivUpSummary(bigSellAmount, price, 10^27);
    assert fillerPrice == mulDivUpSummary(bigBuyAmount, 10^27, bigSellAmount);
    assert bigSellAmount >= sellAmount;


    assert buyTokenViaFill == mulDivUpSummary(sellAmount, fillerPrice, 10^27);

    // Proven in buyCalculationFillFlow
    require buyTokenViaFill <= (sellAmount * price + 10^27 - 1) / 10^27 + (sellAmount + 1) / 10^27 + 2;
    assert buyTokenViaBid == (sellAmount * price + 10^27 - 1) / 10^27;
    assert buyTokenViaFill - buyTokenViaBid <= (sellAmount + 1) / 10^27 + 2;

    assert buyBalanceAfterBid + (sellAmount+1) / 10^27 + 2 >= buyBalanceAfterFill;
}


rule buyCalculationFillFlow() {
    uint256 bigSellAmount;
    uint256 sellAmount;
    uint256 price;
    uint256 sellerPrice;

    /*
        buyAmount <= (sellAmount * fillerPrice / D27 + 1)
        fillerPrice <= bigBuyAmount * D27 / bigSellAmount + +1
        bigBuyAmount <= bigSellAmount * price / D27 + 1

        fillerPrice <= (bigSellAmount * price / D27 + 1) * D27 / bigSellAmount + 1 <= (bigSellAmount * price + D27) / bigSellAmount + 1 == price + D27 / bigSellAmount + 1
        buyAmount <= (sellAmount * (price + D27 / bigSellAmount + 1) / D27) + 1
                <= (sellAmount * price + (sellAmount * D27 / bigSellAmount) + sellAmount) / D27 + 1
                <= (sellAmount * price + D27 + sellAmount) / D27 + 1
                <= ((sellAmount + price + D27 - 1) + (sellAmount + 1)) / D27 + 1
                <= (sellAmount + price + D27 - 1) / D27 + (sellAmount + 1) / D27 + 2
    */

    require bigSellAmount >= sellAmount;

    uint256 bigBuyAmount = mulDivUpSummary(bigSellAmount, price, 10^27);
    uint256 fillerPrice = mulDivUpSummary(bigBuyAmount, 10^27, bigSellAmount);
    uint256 buyTokenViaFill = mulDivUpSummary(sellAmount, fillerPrice, 10^27);
    assert buyTokenViaFill <= (sellAmount * price + 10^27 - 1) / 10^27 + (sellAmount + 1) / 10^27 + 2;
}


rule fillerIsNeverWorse(env e) {
    address token1;
    address token2;
    address token3;
    uint256 id;
    token1, token2, token3, id = setupAssumptionsWithAuction(e);

    address sellToken; 
    require ghostIndexes[to_bytes32(sellToken)] != 0;
    address buyToken;
    require ghostIndexes[to_bytes32(buyToken)] != 0;
    address otherToken;
    require otherToken != sellToken && otherToken != buyToken;

    uint256 sellAmount;
    uint256 maxBuyAmount;
    bool withCallback;
    bytes data;

    address targetFiller;
    bytes32 salt;

    address filler = MockTrustedFiller.getFillerAddress();

    require balanceByToken[sellToken][filler] == 0;
    require balanceByToken[buyToken][filler] == 0;
    require balanceByToken[otherToken][filler] == 0;

    storage initialStorage = lastStorage;
    bid(e,id, sellToken, buyToken,sellAmount,maxBuyAmount,withCallback,data);

    uint256 buyBalanceAfterBid = balanceByToken[buyToken][currentContract];


    address trustedFiller = createTrustedFill(e, id, sellToken, buyToken, targetFiller, salt) at initialStorage;
    filler.exchange(e,sellAmount);
    closeFill(e);

    uint256 buyBalanceAfterFill = balanceByToken[buyToken][currentContract];

    assert buyBalanceAfterBid <= buyBalanceAfterFill;
}

rule otherTokensAreTheSameWithFills(env e) {
    address token1;
    address token2;
    address token3;
    uint256 id;
    token1, token2, token3, id = setupAssumptionsWithAuction(e);

    address sellToken; 
    require ghostIndexes[to_bytes32(sellToken)] != 0;
    address buyToken;
    require ghostIndexes[to_bytes32(buyToken)] != 0;
    address otherToken;
    require otherToken != sellToken && otherToken != buyToken;

    uint256 sellAmount;
    uint256 maxBuyAmount;
    bool withCallback;
    bytes data;

    address targetFiller;
    bytes32 salt;

    address filler = MockTrustedFiller.getFillerAddress();

    require balanceByToken[sellToken][filler] == 0;
    require balanceByToken[buyToken][filler] == 0;
    require balanceByToken[otherToken][filler] == 0;

    storage initialStorage = lastStorage;
    bid(e,id, sellToken, buyToken,sellAmount,maxBuyAmount,withCallback,data);

    uint256 sellBalanceAfterV1 = balanceByToken[sellToken][currentContract];
    uint256 buyBalanceAfterV1 = balanceByToken[buyToken][currentContract];
    uint256 otherBalanceAfterV1 = balanceByToken[otherToken][currentContract];


    address trustedFiller = createTrustedFill(e, id, sellToken, buyToken, targetFiller, salt) at initialStorage;
    filler.exchange(e,sellAmount);
    closeFill(e);

    uint256 sellBalanceAfterV2 = balanceByToken[sellToken][currentContract];
    uint256 buyBalanceAfterV2 = balanceByToken[buyToken][currentContract];
    uint256 otherBalanceAfterV2 = balanceByToken[otherToken][currentContract];

    assert sellBalanceAfterV1 == sellBalanceAfterV2;
    assert otherBalanceAfterV1 == otherBalanceAfterV2;
}




rule fillersCannotExceedTheTradedCapSimple(env e) {
    uint256 id;
    _,_,_,id = setupAssumptionsWithAuction(e);
    address targetFiller;
    address filler;
    bytes32 salt;

    assumeNoTrustedFiller(e);

    address sellToken; 
    address buyToken;
    uint256 sellAmount;
    require currentContract.auctions[id].traded[buyToken] == 0;
    
    filler = createTrustedFill(e, id, sellToken, buyToken, targetFiller, salt);
    filler.exchange(e,sellAmount);
    closeFill(e);

    assert currentContract.rebalance.details[buyToken].maxAuctionSize >= currentContract.auctions[id].traded[buyToken];
}

rule fillersCannotExceedTheTradedCap(env e) {
    uint256 id;
    _,_,_,id = setupAssumptionsWithAuction(e);
    address targetFiller;
    address filler;
    bytes32 salt;

    assumeNoTrustedFiller(e);

    address sellToken; 
    address buyToken;
    uint256 sellAmount1;
    uint256 sellAmount2;
    require currentContract.auctions[id].traded[buyToken] == 0;
    
    filler = createTrustedFill(e, id, sellToken, buyToken, targetFiller, salt);
    filler.exchange(e,sellAmount1);
    filler.exchange(e,sellAmount2);
    closeFill(e);

    assert currentContract.rebalance.details[buyToken].maxAuctionSize >= currentContract.auctions[id].traded[buyToken];
}


rule closeTrustedFillUpdatesTradedAmountsCorrectly(env e) {
    uint256 id;
    _,_,_,id = setupAssumptionsWithAuction(e);

    address filler = MockTrustedFiller.getFillerAddress();

    address sellToken = filler.sellToken(e); 
    require ghostIndexes[to_bytes32(sellToken)] != 0;
    address buyToken = filler.buyToken(e);
    require ghostIndexes[to_bytes32(buyToken)] != 0;
    require sellToken != buyToken;

    uint256 initialSellAmount = MockTrustedFiller.sellAmount;
    uint256 sellTokenInFill = balanceByToken[sellToken][filler];
    require sellTokenInFill <= initialSellAmount;
    uint256 buyTokenInFill = balanceByToken[buyToken][filler];

    uint256 sellTraded = currentContract.auctions[id].traded[sellToken];
    uint256 buyTraded = currentContract.auctions[id].traded[buyToken];

    closeFill(e);

    assert currentContract.auctions[id].traded[sellToken] == sellTraded + initialSellAmount - sellTokenInFill;
    assert currentContract.auctions[id].traded[buyToken] == buyTraded + buyTokenInFill;
}

rule removeTokenFromBasket(env e, method f, calldataarg args)
filtered { f -> !f.isView && !isHarnessOnly(f) }
{
    address token1;
    address token2;
    address token3;
    uint256 id;
    token1, token2, token3, _ = setupAssumptionsWithAuction(e);

    address token;
    // Token is one of the tokens in the basket
    require token == token1 || token == token2 || token == token3;

    f(e,args);

    // Out of basket => balance is 0 or the token was removed by admin
    assert ghostIndexes[to_bytes32(token)] == 0 => (balanceByToken[token][currentContract] == 0 || (f.selector == sig:removeFromBasket(address).selector && hasRole(e,getAdminRole(e),e.msg.sender)));
}