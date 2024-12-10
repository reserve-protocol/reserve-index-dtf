// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFolioDAOFeeRegistry {
    error FolioDAOFeeRegistry__FeeRecipientAlreadySet();
    error FolioDAOFeeRegistry__InvalidFeeRecipient();
    error FolioDAOFeeRegistry__InvalidFeeNumerator();
    error FolioDAOFeeRegistry__InvalidRoleRegistry();
    error FolioDAOFeeRegistry__InvalidCaller();
    error FolioDAOFeeRegistry__RTokenAlreadySet();

    event FeeRecipientSet(address indexed feeRecipient);
    event DefaultFeeNumeratorSet(uint256 defaultFeeNumerator);
    event TokenFeeNumeratorSet(address indexed rToken, uint256 feeNumerator, bool isActive);

    function getFeeDetails(
        address rToken
    ) external view returns (address recipient, uint256 feeNumerator, uint256 feeDenominator);
}
