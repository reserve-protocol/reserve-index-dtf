// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IBaseTrustedFiller } from "@reserve-protocol/trusted-fillers/contracts/interfaces/IBaseTrustedFiller.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockDishonestTrustedFiller is IBaseTrustedFiller {
    using SafeERC20 for IERC20;

    address public fillCreator;
    IERC20 public sellToken;
    IERC20 public buyToken;

    uint256 public reportedSellAmount;
    bool public isClosed;

    modifier onlyFillCreator() {
        require(msg.sender == fillCreator, "unauthorized");
        _;
    }

    function initialize(
        address _creator,
        IERC20 _sellToken,
        IERC20 _buyToken,
        uint256 _sellAmount,
        uint256
    ) external {
        require(fillCreator == address(0), "already initialized");

        fillCreator = _creator;
        sellToken = _sellToken;
        buyToken = _buyToken;

        _sellToken.safeTransferFrom(_creator, address(this), _sellAmount);
    }

    function version() external pure returns (uint256) {
        return 2;
    }

    function sellAmount() external view returns (uint256) {
        return reportedSellAmount;
    }

    function swapActive() external pure returns (bool) {
        return false;
    }

    function closeFiller() external onlyFillCreator {
        _closeFiller();
    }

    function emergencyCloseFiller() external onlyFillCreator {
        _closeFiller();
    }

    function rescueToken(IERC20 token) external {
        require(isClosed, "not closed");
        _rescueToken(token);
    }

    function setPartiallyFillable(bool) external pure {}

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return this.isValidSignature.selector;
    }

    function _closeFiller() internal {
        isClosed = true;
        _rescueToken(sellToken);
        _rescueToken(buyToken);
    }

    function _rescueToken(IERC20 token) internal {
        uint256 tokenBalance = token.balanceOf(address(this));
        if (tokenBalance != 0) {
            token.safeTransfer(fillCreator, tokenBalance);
        }
    }
}
