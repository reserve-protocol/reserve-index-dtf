// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../contracts/Folio.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MathLib } from "@utils/MathLib.sol";
import { 
    DEFAULT_ADMIN_ROLE,
    MAX_TVL_FEE, 
    MAX_FEE_RECIPIENTS, 
    MAX_TTL, 
    MAX_LIMIT, 
    MAX_WEIGHT, 
    MAX_TOKEN_BUY_AMOUNT, 
    MAX_TOKEN_PRICE, 
    MAX_TOKEN_PRICE_RANGE,
    MIN_MINT_FEE
} from "../../contracts/utils/Constants.sol";

/**
 * @title FolioHarness
 * @notice Harness to expose internal functions and state for verification
 */
contract FolioHarness is Folio{
    using EnumerableSet for EnumerableSet.AddressSet;


    // totalAssets for just one token
    function getBalanceOfToken(address token) external view returns (uint256) {
        return _balanceOfToken(IERC20(token));
    }
    
    // Helper to check if auction is active
    function isAuctionActive(uint256 auctionId) public view returns (bool) {
        if (auctionId >= nextAuctionId) {
            return false;
        }
        
        Auction storage auction = auctions[auctionId];
        return auction.startTime <= block.timestamp && block.timestamp <= auction.endTime && auction.rebalanceNonce == rebalance.nonce;
    }
    

    // To avoid potential overflows, we might want to summarize this in CVL to use mathints.
    function _isTokenInSurplus(uint256 currentBalance, uint256 totalShares, uint256 limitH, uint256 weightH) internal pure returns (bool) {
        // return ((limitH * weightH / 1e18)  * totalShares) / 1e27 < currentBalance;
        return Math.mulDiv(Math.mulDiv(limitH, weightH, 1e18, Math.Rounding.Ceil), totalShares, 1e27, Math.Rounding.Ceil) < currentBalance;
    }
    
    // Check if token is in surplus (current balance > high limit)
    function isTokenInSurplus(address token) external view returns (bool) {
        uint256 currentBalance = _balanceOfToken(IERC20(token));
        uint256 totalShares = totalSupply();
        
        if (totalShares == 0) return false;
        
        RebalanceDetails storage details = rebalance.details[token];
        if (!details.inRebalance) return false;
        
        // Calculate high threshold: limits.high * weight.high * totalShares
        // Note: This is simplified - actual calculation involves proper unit conversions
        
        return _isTokenInSurplus(currentBalance, totalShares, rebalance.limits.high, details.weights.high);
    }
    
    function _isTokenInDeficit(uint256 currentBalance, uint256 totalShares, uint256 limitL, uint256 weightL) internal pure returns (bool) {
        return ((limitL * weightL / 1e18)  * totalShares) / 1e27 > currentBalance;
    }

    // Check if token is in deficit (current balance < low limit)  
    function isTokenInDeficit(address token) external view returns (bool) {
        uint256 currentBalance = _balanceOfToken(IERC20(token));
        uint256 totalShares = totalSupply();
        
        if (totalShares == 0) return false;
        
        RebalanceDetails storage details = rebalance.details[token];
        if (!details.inRebalance) return false;
        
        // Calculate low threshold: limits.low * weight.low * totalShares  
        return _isTokenInDeficit(currentBalance, totalShares, rebalance.limits.low, details.weights.low);
    }

    function getPendingFeeSharesZeroFees()
        public
        view
        returns (uint256, uint256, uint256)
    {
        return (daoPendingFeeShares, feeRecipientsPendingFeeShares, (block.timestamp / ONE_DAY) * ONE_DAY);
    }

    function getTotalFeeShares() public view returns (uint256) {
        return daoPendingFeeShares + feeRecipientsPendingFeeShares;
    }


    function totalSupplyWithoutFees() external view returns (uint256) {
        return ERC20Upgradeable.totalSupply();
    }

    function toBytes32(address value) public pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function toUint256(bytes32 value) public pure returns (uint256) {
        return uint256(value);
    }  

    function getPrice(IERC20 sellToken, IERC20 buyToken) external view returns (uint256) {
        uint256 auctionId = nextAuctionId-1;
        require(isAuctionActive(auctionId), "id provided is of an inactive auction");

        return RebalancingLib._price(rebalance, auctions[auctionId], sellToken, buyToken);
    }

    function closeFill() external {
        if (address(activeTrustedFill) != address(0)) {
            RebalancingLib.closeTrustedFill(auctions[nextAuctionId - 1], activeTrustedFill);
        }
    }

    function changeLimits(uint256 c) external {
        require(c>0, "invalid parameter");
        rebalance.limits.low /= c;
        rebalance.limits.spot /= c;
        rebalance.limits.high /= c;
    }

    function changeWeights(uint256 c, address token) external {
        require(c>0, "invalid parameter");
        rebalance.details[token].weights.low *= c;
        rebalance.details[token].weights.spot *= c;
        rebalance.details[token].weights.high *= c;
    }

    function getMAX_MINT_FEE() public pure returns (uint256) { return MAX_MINT_FEE; }
    function getMAX_FOLIO_FEE() public pure returns (uint256) {return MAX_FOLIO_FEE; }
    function getMIN_AUCTION_LENGTH() public pure returns (uint256) { return MIN_AUCTION_LENGTH; }
    function getMAX_AUCTION_LENGTH() public pure returns (uint256) { return MAX_AUCTION_LENGTH; }

    function getAdminRole() public pure returns (bytes32) { return DEFAULT_ADMIN_ROLE; }

}