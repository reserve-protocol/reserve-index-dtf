// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFolioFeeRegistry {
    error FolioFeeRegistry__FeeRecipientAlreadySet();
    error FolioFeeRegistry__InvalidFeeRecipient();
    error FolioFeeRegistry__InvalidFeeNumerator();
    error FolioFeeRegistry__InvalidRoleRegistry();
    error FolioFeeRegistry__InvalidCaller();
    error FolioFeeRegistry__RTokenAlreadySet();

    event FeeRecipientSet(address indexed feeRecipient);
    event DefaultFeeNumeratorSet(uint256 defaultFeeNumerator);
    event TokenFeeNumeratorSet(address indexed rToken, uint256 feeNumerator, bool isActive);

    function getFeeDetails(
        address rToken
    ) external view returns (address recipient, uint256 feeNumerator, uint256 feeDenominator);
}
