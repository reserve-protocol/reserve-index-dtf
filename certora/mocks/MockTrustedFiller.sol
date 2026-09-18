// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IBaseTrustedFiller } from "@reserve-protocol/trusted-fillers/contracts/interfaces/IBaseTrustedFiller.sol";

/**
 * @title MockTrustedFiller
 * @notice Mock trusted filler contract for CVL verification
 * @dev Implements IBaseTrustedFiller interface for testing purposes
 */
contract MockTrustedFiller is IBaseTrustedFiller {
    using SafeERC20 for IERC20;

    // State variables
    address public creator;
    IERC20 public sellToken;
    IERC20 public buyToken;
    uint256 public sellAmount;
    uint256 public minBuyAmount;
    bool public swapActive;
    bool public partiallyFillable;

    // Price in Reserve protocol convention: buyToken/sellToken
    uint256 public price; // D27{buyTok/sellTok}: minBuyAmount * D27 / sellAmount

    /**
     * @notice Initialize the trusted filler
     * @param _creator The address of the Folio contract that created this filler
     * @param _sellToken The token to sell
     * @param _buyToken The token to buy
     * @param _sellAmount Total amount of sell tokens
     * @param _minBuyAmount Minimum amount of buy tokens expected
     */
    function initialize(
        address _creator,
        IERC20 _sellToken,
        IERC20 _buyToken,
        uint256 _sellAmount,
        uint256 _minBuyAmount
    ) external override {
        require(_creator != address(0), "MockTrustedFiller: invalid creator");
        require(address(_sellToken) != address(0), "MockTrustedFiller: invalid sell token");
        require(address(_buyToken) != address(0), "MockTrustedFiller: invalid buy token");
        require(_sellAmount > 0, "MockTrustedFiller: invalid sell amount");
        require(_minBuyAmount > 0, "MockTrustedFiller: invalid min buy amount");

        creator = _creator;
        sellToken = _sellToken;
        buyToken = _buyToken;
        sellAmount = _sellAmount;
        minBuyAmount = _minBuyAmount;
        swapActive = true;

        // Calculate price in Reserve protocol convention: buyToken/sellToken
        // D27{buyTok/sellTok} = {buyTok} * D27 / {sellTok}
        price = Math.mulDiv(_minBuyAmount, 1e27, _sellAmount, Math.Rounding.Ceil);

        // Pull all approved sellTokens from the creator (Folio)     
        _sellToken.safeTransferFrom(_creator, address(this), _sellAmount);
    }

    /**
     * @notice Exchange sell tokens for buy tokens according to the set ratio
     * @param sellAmountToExchange Amount of sell tokens to exchange
     * @dev Anyone can call this to exchange tokens at the predetermined ratio
     */
    function exchange(uint256 sellAmountToExchange) external returns (uint256) {
        require(sellAmountToExchange > 0, "MockTrustedFiller: invalid amount");

        uint256 availableSellTokens = sellToken.balanceOf(address(this));
        require(availableSellTokens >= sellAmountToExchange, "MockTrustedFiller: insufficient sell tokens");

        // Calculate required buy tokens using price: sellAmountToExchange * price / D27
        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        uint256 requiredBuyTokens = Math.mulDiv(sellAmountToExchange, price, 1e27, Math.Rounding.Ceil);
        
        // Check caller has enough buy tokens
        require(buyToken.balanceOf(msg.sender) >= requiredBuyTokens, "MockTrustedFiller: insufficient caller buy tokens");

        // Transfer buy tokens from caller to this contract
        buyToken.safeTransferFrom(msg.sender, address(this), requiredBuyTokens);
        
        // Transfer sell tokens from this contract to caller
        sellToken.safeTransfer(msg.sender, sellAmountToExchange);

        return requiredBuyTokens;
    }

    /**
     * @notice Close the filler and return all tokens to creator
     */
    function _closeFiller() internal {
        // require(swapActive, "MockTrustedFiller: already closed");
        
        swapActive = false;

        // Return all tokens to creator
        // uint256 sellBalance = sellToken.balanceOf(address(this));
        // uint256 buyBalance = buyToken.balanceOf(address(this));

        rescueToken(sellToken);
        rescueToken(buyToken);

        // Reset state (except creator which stays the same)
        // sellToken = IERC20(address(0));
        // buyToken = IERC20(address(0));
        // sellAmount = 0; // we check this value for traded amounts after we close the fill
        // minBuyAmount = 0;
        // price = 0;
    }

    function closeFiller() external override {
        _closeFiller();
    }

    function emergencyCloseFiller() external {
        _closeFiller();
    }

    /**
     * @notice Rescue tokens (emergency function)
     * @param token Token to rescue
     */
    function rescueToken(IERC20 token) public override {
        require(msg.sender == creator, "MockTrustedFiller: only creator");
        
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            token.safeTransfer(creator, balance);
        }
    }

    /**
     * @notice Set whether the filler can be partially filled
     * @param _partiallyFillable Whether partial fills are allowed
     */
    function setPartiallyFillable(bool _partiallyFillable) external override {
        require(msg.sender == creator, "MockTrustedFiller: only creator");
        partiallyFillable = _partiallyFillable;
    }

    /**
     * @notice Check if a signature is valid (EIP-1271)
     * @param hash Hash to verify
     * @param signature Signature to check
     * @return magicValue Magic value if signature is valid
     */
    function isValidSignature(bytes32 hash, bytes memory signature) 
        external 
        view 
        override 
        returns (bytes4 magicValue) 
    {
        // For mock purposes, always return invalid signature
        // In a real implementation, this would verify signatures
        return 0x00000000;
    }

    // Getter functions for verification
    function getPrice() external view returns (uint256) {
        return price;
    }

    function getSellTokenBalance() external view returns (uint256) {
        return sellToken.balanceOf(address(this));
    }

    function getBuyTokenBalance() external view returns (uint256) {
        return buyToken.balanceOf(address(this));
    }

    function getFillerAddress() external view returns (address) {
        return address(this);
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}