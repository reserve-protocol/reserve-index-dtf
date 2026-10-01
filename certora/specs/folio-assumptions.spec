import "folio-prerequisities.spec";

function assumeNoFeeRecalculation(env e) {
    require e.block.timestamp - lastPoke() < 86400;
}

function assumeNoTrustedFillers() {
    require !currentContract.trustedFillerEnabled;
    require currentContract.activeTrustedFill == 0;
}

function assumeThreeTokens() returns (address, address, address) {
    address[] tokens;
    tokens, _ = totalAssets();
    require tokens.length == 3;
    require tokens[0] != tokens[1]; // set property
    require tokens[2] != tokens[0];
    require tokens[2] != tokens[1];
    require toUint256(currentContract.basket._inner._values[0]) <= max_uint160; // max address bound
    require toUint256(currentContract.basket._inner._values[1]) <= max_uint160;
    require toUint256(currentContract.basket._inner._values[2]) <= max_uint160;

    requireInvariant sharesNotInBasket();

    return (tokens[0], tokens[1], tokens[2]);
}

function setupAssumptions(env e) returns (address, address, address) {
    requireInvariant totalSupplySumOfBalances(e);
    requireInvariant setInvariant;

    requireInvariant storageVariablesWithinLimits;
    requireInvariant noSharesOwnedByProtocol(e);
    
    assumeNoFeeRecalculation(e);
    
    address token1;
    address token2;
    address token3;
    token1, token2, token3 = assumeThreeTokens();

    return (token1, token2, token3);
}

function setupAssumptionsWithRebalance(env e) returns (address, address, address) {
    address token1;
    address token2;
    address token3;
    token1, token2, token3 = setupAssumptions(e);

    requireInvariant outOfBasketNotInRebalance;
    requireInvariant onlyTokensInBasketAreInRebalance;
    requireInvariant rebalanceTokenPrices;
    requireInvariant rebalanceTokenWeights;
    requireInvariant rebalanceBounds;
    requireInvariant positivePricesIfInRebalance;

    return (token1, token2, token3);
}

function setupAssumptionsWithAuction(env e) returns (address, address, address, uint256) {
    address token1;
    address token2;
    address token3;
    token1, token2, token3 = setupAssumptionsWithRebalance(e);

    requireInvariant ifAuctionIsInitializedLimitsAreCorrect(e);
    requireInvariant pastAuctionsAreClosed(e);
    requireInvariant futureAuctionsAreNotInitialized;
    requireInvariant onlyActiveAuctionId(e);
    requireInvariant auctionPricesRespectRebalance;

    uint256 id = require_uint256(currentContract.nextAuctionId - 1);

    return (token1, token2, token3, id);
}