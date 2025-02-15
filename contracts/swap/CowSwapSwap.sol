// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { GPv2OrderLib, COWSWAP_GPV2_SETTLEMENT, COWSWAP_GPV2_VAULT_RELAYER } from "../utils/GPv2OrderLib.sol";
import { Versioned } from "@utils/Versioned.sol";

import { ISwap } from "@interfaces/ISwap.sol";

uint256 constant D27 = 1e27; // D27

/// Swap MUST occur in the same block as initialization
/// Expected to be newly deployed in the pre-hook of a CowSwap order
/// Ideally `close()` is called in the end as a post-hook, but this is not relied upon
contract CowSwapSwap is Initializable, Versioned, ISwap {
    using GPv2OrderLib for GPv2OrderLib.Data;
    using SafeERC20 for IERC20;

    error CowSwapSwap__Unfunded();
    error CowSwapSwap__Unauthorized();
    error CowSwapSwap__SlippageExceeded();
    error CowSwapSwap__InvalidCowSwapOrder();
    error CowSwapSwap__InvalidEIP1271Signature();

    address public beneficiary;
    IERC20 public sell;
    IERC20 public buy;
    uint256 public sellAmount; // {sellTok}
    uint256 public price; // D27{buyTok/sellTok}
    uint256 public blockInitialized; // {block}

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// Initialize the swap, transferring in `_sellAmount` of the `_sell` token
    /// @dev Built for the pre-hook of a CowSwap order
    function initialize(
        address _beneficiary,
        IERC20 _sell,
        IERC20 _buy,
        uint256 _sellAmount,
        uint256 _minBuyAmount
    ) external initializer {
        beneficiary = _beneficiary;
        sell = _sell;
        buy = _buy;
        sellAmount = _sellAmount;
        blockInitialized = block.number;

        // D27{buyTok/sellTok} = {buyTok} * D27 / {sellTok}
        price = (_minBuyAmount * D27) / _sellAmount;

        sell.forceApprove(COWSWAP_GPV2_VAULT_RELAYER, _sellAmount);
        sell.safeTransferFrom(_beneficiary, address(this), _sellAmount);
    }

    /// @dev Validates an in-same-block cowswap order for a partial fill via EIP-1271
    function isValidSignature(bytes32 _hash, bytes calldata signature) external view returns (bytes4) {
        require(block.number == blockInitialized, CowSwapSwap__Unauthorized());

        // decode the signature to get the CowSwap order
        GPv2OrderLib.Data memory order = abi.decode(signature, (GPv2OrderLib.Data));

        // verify order details

        require(_hash == order.hash(COWSWAP_GPV2_SETTLEMENT.domainSeparator()), CowSwapSwap__InvalidEIP1271Signature());

        // D27{buyTok/sellTok} = {buyTok} * D27 / {sellTok}
        uint256 orderPrice = (order.buyAmount * D27) / order.sellAmount;
        require(
            order.sellToken == address(sell) &&
                order.buyToken == address(buy) &&
                order.feeAmount == 0 &&
                order.partiallyFillable &&
                order.receiver == address(this),
            CowSwapSwap__InvalidCowSwapOrder()
        );
        require(
            order.sellAmount != 0 && order.sellAmount <= sellAmount && orderPrice >= price,
            CowSwapSwap__SlippageExceeded()
        );

        // If all checks pass, return the magic value
        // bytes4(keccak256("isValidSignature(bytes32,bytes)")
        return 0x1626ba7e;
    }

    /// Collect all balances back to the beneficiary
    /// @dev Built for the post-hook of a CowSwap order (but can be called anytime)
    function close() external {
        uint256 sellBal = sell.balanceOf(address(this));
        uint256 buyBal = buy.balanceOf(address(this));

        sell.safeTransfer(beneficiary, sellBal);
        buy.safeTransfer(beneficiary, buyBal);
    }
}
