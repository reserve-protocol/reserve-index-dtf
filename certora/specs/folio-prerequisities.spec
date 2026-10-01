import "Summaries/set.spec";
import "Summaries/ERC20s_CVL.spec";
import "summaries-Folio.spec";
import "folio-methods-common.spec";

methods {
    // Specific methods for this property
    function auctions(uint256) external returns (uint256, uint256, uint256) envfree;

    // ERC20Upgradeable internal functions summary 
    function ERC20Upgradeable.totalSupply() internal returns (uint256) => totalSupplyGhost; // We can just summarize the balances - the fees that have not been minted will be added when the FolioHarness.totalSupply is called.

    function FolioHarness.balanceOf(address account) internal returns (uint256) => 
            tokenBalanceOf(currentContract, account);

    function FolioHarness.transfer(address to, uint256 amount) internal returns (bool) with (env e) => 
            transferFromFolioCVL(currentContract, e.msg.sender, to, amount);
    
    function FolioHarness.transferFrom(address from, address to, uint256 amount) internal returns (bool) with (env e) => 
        transferFromFromFolioCVL(currentContract, e.msg.sender, from, to, amount);
    
    function ERC20Upgradeable._mint(address account, uint256 value) internal => mintCVL(account, value);
    function ERC20Upgradeable._burn(address account, uint256 value) internal => burnCVL(account, value);

    function getTotalFeeShares() external returns (uint256) envfree;
    function FolioHarness.getPendingFeeSharesZeroFees() external returns (uint256, uint256, uint256);
    function FolioHarness.totalSupplyWithoutFees() external returns (uint256) envfree;
    function Folio._getPendingFeeShares() internal returns (uint256, uint256, uint256) with (env e)=> getPendingFeeSharesCVL(e);
    function Folio.distributeFees() internal => distributeFeesCVL();

    function RebalancingLib._price(IFolio.Rebalance storage rebalance, IFolio.Auction storage auction, address sellToken, address buyToken) internal returns (uint256) => RebalancingLibHarness._priceSimplified(rebalance, auction, sellToken, buyToken);
    function RebalancingLibHarness._interpolatePrice(uint256 startPrice, uint256 endPrice, uint256 elapsed, uint256 auctionLength) internal returns (uint256) => interpolatePriceGhost(startPrice, endPrice, elapsed, auctionLength);

    function toBytes32(address) external returns (bytes32) envfree;
    function toUint256(bytes32) external returns (uint256) envfree;

    //// CONSTANTS ////
    function getMAX_MINT_FEE() external returns (uint256) envfree;
    function getMAX_FOLIO_FEE() external returns (uint256) envfree;
    function getMIN_AUCTION_LENGTH() external returns (uint256) envfree;
    function getMAX_AUCTION_LENGTH() external returns (uint256) envfree;
}

////////////////////////////////////////////////////////////////////////////
//                          Summary functions                             //
////////////////////////////////////////////////////////////////////////////


function transferFromFolioCVL(address token, address from, address to, uint256 amount) returns bool {
    require to != currentContract, "prevent accidental donations, line 1156";
    return transferCVL(token, from, to, amount);
}

function transferFromFromFolioCVL(address token, address spender, address from, address to, uint256 amount) returns bool {
    require to != currentContract, "prevent accidental donations, line 1156";
    return transferFromCVL(token, spender, from, to, amount);
}


function mintCVL(address account, uint256 value) {
    revertOn(account == 0 || account == currentContract);
    totalSupplyGhost = require_uint256(totalSupplyGhost + value);
    balanceByToken[currentContract][account] = require_uint256(balanceByToken[currentContract][account] + value);
}

function burnCVL(address account, uint256 value) {
    revertOn(account == 0 || account == currentContract);
    totalSupplyGhost = require_uint256(totalSupplyGhost - value);
    balanceByToken[currentContract][account] = require_uint256(balanceByToken[currentContract][account] - value);
}

function getPendingFeeSharesCVL(env e) returns (uint256, uint256, uint256) {
    uint256 daoShares;
    uint256 feeRecipientShares;
    uint256 accountedUntil;
    daoShares, feeRecipientShares, accountedUntil = FolioHarness.getPendingFeeSharesZeroFees(e);
    return (daoShares, feeRecipientShares, accountedUntil);
}

function distributeFeesCVL() {
    return;
}

////////////////////////////////////////////////////////////////////////////
//                            Definitions                                 //
////////////////////////////////////////////////////////////////////////////

definition isHarnessOnly(method f) returns bool = 
    f.selector == sig:changeLimits(uint256).selector ||
    f.selector == sig:changeWeights(uint256,address).selector ||
    f.selector == sig:closeFill().selector;

////////////////////////////////////////////////////////////////////////////
//                              GHOSTS                                    //
////////////////////////////////////////////////////////////////////////////

ghost uint256 totalSupplyGhost {
    init_state axiom totalSupplyGhost == 0;
}

ghost interpolatePriceGhost(uint256, uint256, uint256, uint256) returns uint256;

////////////////////////////////////////////////////////////////////////////
//                       Simple setup checks                              //
////////////////////////////////////////////////////////////////////////////

invariant totalSupplySumOfBalances(env e)
    totalSupplyWithoutFees() == (usum address a. balanceByToken[currentContract][a])
    { 
        preserved {     
            requireInvariant setInvariant;
        } 
    }

rule checkTotalSupply(env e) {
    requireInvariant totalSupplySumOfBalances(e);

    uint256 folioShares = totalSupply(e);
    assert totalSupplyWithoutFees() + getTotalFeeShares() == folioShares;
}


invariant onlyActiveAuctionId(env e)
    forall uint256 id. 
        (
            currentContract.auctions[id].startTime < e.block.timestamp &&
            currentContract.auctions[id].endTime >= e.block.timestamp && 
            currentContract.auctions[id].rebalanceNonce == currentContract.rebalance.nonce
        )
            =>
        (
            currentContract.nextAuctionId == id + 1
        )
        {
            preserved with (env e2) {
                requireInvariant futureAuctionsAreNotInitialized_weak; // due to grounding causing overapproximation that breaks the rule with stronger assumption, we need to use a weaker assumption here
                requireInvariant pastAuctionsAreClosed(e);
                requireInvariant ifAuctionIsInitializedLimitsAreCorrect(e);
                require e == e2;
                require e.block.timestamp > 0;
            }
        }

invariant futureAuctionsAreNotInitialized_weak()
    forall uint256 id . id >= currentContract.nextAuctionId =>
    (
        currentContract.auctions[id].endTime == 0 &&
        currentContract.auctions[id].startTime == 0 &&
        currentContract.auctions[id].rebalanceNonce == 0
    );


invariant futureAuctionsAreNotInitialized()
    forall uint256 id . forall address token . id >= currentContract.nextAuctionId =>
    (
        currentContract.auctions[id].endTime == 0 &&
        currentContract.auctions[id].startTime == 0 &&
        currentContract.auctions[id].rebalanceNonce == 0 &&
        currentContract.auctions[id].prices[token].low == 0 &&
        currentContract.auctions[id].prices[token].high == 0 &&
        currentContract.auctions[id].traded[token] == 0
    );

// When using environment variable in the preserved block, it refers to a different environment, hence we need to ensure that does not happen.
invariant pastAuctionsAreClosed(env e)
    forall uint256 id. (id + 1) < currentContract.nextAuctionId =>
    (
        currentContract.auctions[id].endTime < e.block.timestamp || currentContract.auctions[id].rebalanceNonce < currentContract.rebalance.nonce 
    )
    {
        preserved with (env e2) {
            requireInvariant futureAuctionsAreNotInitialized;
            requireInvariant ifAuctionIsInitializedLimitsAreCorrect(e);
            require e == e2;
            require e.block.timestamp > 0;
        }
    }


rule pastAuctionsAreClosedAsRule(env e1, env e2, env e3) {
    requireInvariant futureAuctionsAreNotInitialized;
    requireInvariant ifAuctionIsInitializedLimitsAreCorrect(e1);
    require e1.block.timestamp > 0;
    
    require forall uint256 id. (id + 1) < currentContract.nextAuctionId => 
        (currentContract.auctions[id].endTime < e1.block.timestamp || currentContract.auctions[id].rebalanceNonce < currentContract.rebalance.nonce);

    require e1.block.timestamp <= e2.block.timestamp && e2.block.timestamp <= e3.block.timestamp;

    calldataarg args;
    openAuction(e2,args);

    assert forall uint256 id. (id + 1) < currentContract.nextAuctionId => 
        (currentContract.auctions[id].endTime < e3.block.timestamp || currentContract.auctions[id].rebalanceNonce < currentContract.rebalance.nonce);
}

invariant ifAuctionIsInitializedLimitsAreCorrect(env e)
    forall uint256 id . forall address token .
        (   // auction is not initialized
            currentContract.auctions[id].rebalanceNonce == 0 && currentContract.auctions[id].startTime == 0 && currentContract.auctions[id].endTime == 0 &&
            currentContract.auctions[id].prices[token].low == 0 && currentContract.auctions[id].prices[token].high == 0 &&
            currentContract.auctions[id].traded[token] == 0
        ) 
            ||
        (
            currentContract.auctions[id].prices[token].low <= currentContract.auctions[id].prices[token].high &&
            currentContract.auctions[id].rebalanceNonce <= currentContract.rebalance.nonce
        )
        {
            preserved {
                requireInvariant rebalanceTokenPrices;
            }
        }


invariant rebalanceBounds()
    (currentContract.rebalance.limits.low == 0 && currentContract.rebalance.limits.high == 0) || (
    currentContract.rebalance.limits.low > 0 &&
    currentContract.rebalance.limits.low <= currentContract.rebalance.limits.spot &&
    currentContract.rebalance.limits.spot <= currentContract.rebalance.limits.high &&
    currentContract.rebalance.limits.high <= 10^27)
    filtered { f -> !isHarnessOnly(f) }

invariant rebalanceTokenWeights() 
    forall address token .
    (
        currentContract.rebalance.details[token].weights.low <= currentContract.rebalance.details[token].weights.spot &&
        currentContract.rebalance.details[token].weights.spot <= currentContract.rebalance.details[token].weights.high &&
        currentContract.rebalance.details[token].weights.high <= 10^54
    )
    filtered { f -> !isHarnessOnly(f) }

// We cannot call functions inside quantified expressions hence we encode MAX_TOKEN_PRICE, MAX_TOKEN_PRICE_RANGE directly.
invariant rebalanceTokenPrices()
    forall address token . 
    (
        currentContract.rebalance.details[token].initialPrices.low == 0 &&
        currentContract.rebalance.details[token].initialPrices.high == 0
    ) 
        ||
    (
        currentContract.rebalance.details[token].initialPrices.low > 0 &&
        currentContract.rebalance.details[token].initialPrices.low <= currentContract.rebalance.details[token].initialPrices.high &&
        currentContract.rebalance.details[token].initialPrices.high <= 10^45 &&
        currentContract.rebalance.details[token].initialPrices.high <= 100 * currentContract.rebalance.details[token].initialPrices.low
    );

invariant onlyTokensInBasketAreInRebalance()
    forall address token . currentContract.rebalance.details[token].inRebalance => 
    ghostIndexes[to_bytes32(token)] != 0
    {
        preserved {     
            requireInvariant setInvariant;
        }
    }

invariant sharesNotInBasket()
    ghostIndexes[toBytes32(currentContract)] == 0
    {
        preserved {     
            requireInvariant setInvariant;
        }
    }

rule trustedFillTokensAreNotShares(env e) {
    requireInvariant setInvariant;
    requireInvariant sharesNotInBasket;
    requireInvariant onlyTokensInBasketAreInRebalance;
    
    calldataarg args;
    createTrustedFill(e,args);

    assert currentContract.activeTrustedFill.sellToken(e) != currentContract &&
            currentContract.activeTrustedFill.buyToken(e) != currentContract;
}

invariant noSharesOwnedByProtocol(env e)
    balanceByToken[currentContract][currentContract] == 0
    {
        preserved {     
            requireInvariant setInvariant;
            require currentContract.activeTrustedFill.sellToken(e) != currentContract;
            require currentContract.activeTrustedFill.buyToken(e) != currentContract;
            requireInvariant sharesNotInBasket;
            requireInvariant onlyTokensInBasketAreInRebalance;
        }
    }


invariant storageVariablesWithinLimits()
    currentContract.mintFee <= getMAX_MINT_FEE() &&
    ((currentContract.maxAuctionLength <= getMAX_AUCTION_LENGTH() && currentContract.maxAuctionLength >= getMIN_AUCTION_LENGTH()) || (currentContract.maxAuctionLength == 0)) &&
    currentContract.folioFeeForSelf <= getMAX_FOLIO_FEE();


invariant outOfBasketNotInRebalance()
    forall address token . ghostIndexes[to_bytes32(token)] == 0 => 
        (
            currentContract.rebalance.details[token].weights.low == 0 &&
            currentContract.rebalance.details[token].weights.spot == 0 &&
            currentContract.rebalance.details[token].weights.high == 0 &&
            currentContract.rebalance.details[token].initialPrices.low == 0 &&
            currentContract.rebalance.details[token].initialPrices.high == 0 &&
            currentContract.rebalance.details[token].inRebalance == false &&
            currentContract.rebalance.details[token].maxAuctionSize == 0
        )
    {
        preserved {     
            requireInvariant setInvariant;
        }
    }

invariant positivePricesIfInRebalance()
    forall address token . currentContract.rebalance.details[token].inRebalance => currentContract.rebalance.details[token].initialPrices.low > 0;

invariant auctionPricesRespectRebalance()
    forall uint256 id . forall address token . 
    (
        currentContract.rebalance.nonce == currentContract.auctions[id].rebalanceNonce &&
        currentContract.rebalance.details[token].inRebalance
    )
        =>
    (
        (currentContract.rebalance.details[token].initialPrices.low <= currentContract.auctions[id].prices[token].low &&
        currentContract.rebalance.details[token].initialPrices.high >= currentContract.auctions[id].prices[token].high &&
        currentContract.auctions[id].prices[token].low <= currentContract.auctions[id].prices[token].high)
        ||
        (currentContract.auctions[id].prices[token].low == 0 && currentContract.auctions[id].prices[token].high == 0)
    )
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
        }
    }


invariant maxAuctionLengthIsNotExceeded() 
    forall uint256 id . currentContract.auctions[id].endTime - currentContract.auctions[id].startTime <= 604800
    {
        preserved {
            requireInvariant storageVariablesWithinLimits;
        }
    }