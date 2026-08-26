import "folio-assumptions.spec";

////////////////////////////////////////////////////////////////////////////
//                               Properties                               //
////////////////////////////////////////////////////////////////////////////


invariant tradedNeverExceedsAuctionSize()
     forall uint256 id . forall address token . 
    (
        currentContract.rebalance.nonce == currentContract.auctions[id].rebalanceNonce &&
        currentContract.rebalance.details[token].inRebalance
    )
        => currentContract.auctions[id].traded[token] <= currentContract.rebalance.details[token].maxAuctionSize

    filtered { f -> f.selector != sig:createTrustedFill(uint256,address,address,address,bytes32).selector }
    {
        preserved with (env e) {
            requireInvariant rebalanceBounds;
            requireInvariant rebalanceTokenWeights;
            requireInvariant rebalanceTokenPrices;
            requireInvariant onlyTokensInBasketAreInRebalance;
            requireInvariant outOfBasketNotInRebalance;
            requireInvariant onlyActiveAuctionId(e);
            requireInvariant futureAuctionsAreNotInitialized;
            requireInvariant pastAuctionsAreClosed(e);
            requireInvariant ifAuctionIsInitializedLimitsAreCorrect(e);
            require currentContract.activeTrustedFill == 0;
            require currentContract.trustedFillerEnabled == false;
        }
    }

rule maxAuctionSizeIsNotExceeded(env e, method f, calldataarg args, address token) 
filtered { f -> f.selector != sig:mint(uint256,address,uint256).selector &&
            f.selector != sig:redeem(uint256,address,address[],uint256[]).selector &&
            f.selector != sig:transfer(address,uint256).selector &&
            f.selector != sig:transferFrom(address,address,uint256).selector &&
            f.selector != sig:initialize(IFolio.FolioBasicDetails,IFolio.FolioAdditionalDetails,IFolio.FolioRegistryIndex,IFolio.FolioFlags,address).selector &&
            f.selector != sig:createTrustedFill(uint256,address,address,address,bytes32).selector &&
            !f.isView 
        }
{
    uint256 auctionId;
    _,_,_,auctionId = setupAssumptionsWithAuction(e);
    assumeNoTrustedFillers();
    
    uint256 limit = currentContract.rebalance.details[token].maxAuctionSize;
    uint256 tradedBefore = currentContract.auctions[auctionId].traded[token];

    uint256 folioBalanceOfTokenBefore = balanceByToken[token][currentContract];

    require tradedBefore <= limit;


    f(e,args);

    uint256 folioBalanceOfTokenAfter = balanceByToken[token][currentContract];
    require folioBalanceOfTokenAfter > 0;

    mathint differenceInTokenBalance = folioBalanceOfTokenBefore - folioBalanceOfTokenAfter;

    uint256 tradedAfter = currentContract.auctions[auctionId].traded[token];
    
    assert differenceInTokenBalance > 0 => tradedBefore + differenceInTokenBalance == tradedAfter;
    assert differenceInTokenBalance < 0 => tradedBefore - differenceInTokenBalance == tradedAfter;
    assert differenceInTokenBalance == 0 => tradedBefore == tradedAfter;
    assert tradedAfter <= limit;
}

rule notInAuctionShareRatioDoesNotDecrease(env e, method f, calldataarg args) 
filtered {
    f -> f.selector != sig:initialize(IFolio.FolioBasicDetails,IFolio.FolioAdditionalDetails,IFolio.FolioRegistryIndex,IFolio.FolioFlags,address).selector &&
    f.selector != sig:createTrustedFill(uint256,address,address,address,bytes32).selector &&
    f.selector != sig:bid(uint256,address,address,uint256,uint256,bool,bytes).selector &&
    f.selector != sig:mint(uint256,address,uint256).selector &&
    !f.isView  
}
{
    
    address token1;
    address token2;
    address token3;
    uint256 id;
    token1, token2, token3, id = setupAssumptionsWithAuction(e);
    assumeNoTrustedFillers();
    
    require e.msg.sender != currentContract;

    address token;
    require ghostIndexes[to_bytes32(token)] != 0, "the other token is in the basket";

    uint256 tokenAmountBefore = getBalanceOfToken(token);
    uint256 folioSharesBefore = totalSupply(e);

    f(e,args);

    uint256 tokenAmountAfter = getBalanceOfToken(token);
    uint256 folioSharesAfter = totalSupply(e);

    assert tokenAmountBefore * folioSharesAfter <= tokenAmountAfter * folioSharesBefore;
}


rule onlyTradeTokensOutsideRange(env e) {
    address token1;
    address token2;
    address token3;
    uint256 id;
    token1, token2, token3, id = setupAssumptionsWithAuction(e);
    assumeNoTrustedFillers();

    address token;
    uint256 balanceBefore = balanceByToken[token][currentContract];

    bool canSell = isTokenInSurplus(e,token);
    bool canBuy = isTokenInDeficit(e,token);
    

    calldataarg args;
    bid(e,args);

    uint256 balanceAfter = balanceByToken[token][currentContract];

    assert balanceBefore != balanceAfter => (canSell || canBuy);
    assert canSell => balanceBefore >= balanceAfter;
    assert canBuy => balanceBefore <= balanceAfter;
    assert balanceBefore > balanceAfter => canSell;
    assert balanceBefore < balanceAfter => canBuy;
    assert !canSell => !isTokenInSurplus(e,token);
    assert !canBuy => !isTokenInDeficit(e,token);
}


rule onlyMintRedeemAndFeesCanChangeShares(env e, method f, calldataarg args)
filtered { f -> f.selector != sig:mint(uint256,address,uint256).selector &&
            f.selector != sig:redeem(uint256,address,address[],uint256[]).selector &&
            f.selector != sig:initialize(IFolio.FolioBasicDetails,IFolio.FolioAdditionalDetails,IFolio.FolioRegistryIndex,IFolio.FolioFlags,address).selector &&
            f.selector != sig:createTrustedFill(uint256,address,address,address,bytes32).selector &&
            !f.isView 
        }
{
    requireInvariant setInvariant;
    assumeThreeTokens();
    requireInvariant outOfBasketNotInRebalance;
    requireInvariant onlyTokensInBasketAreInRebalance;
    assumeNoFeeRecalculation(e);
    assumeNoTrustedFillers();

    uint256 sharesBefore = totalSupply(e);

    f(e,args);

    uint256 sharesAfter = totalSupply(e);

    assert sharesBefore == sharesAfter;
}
