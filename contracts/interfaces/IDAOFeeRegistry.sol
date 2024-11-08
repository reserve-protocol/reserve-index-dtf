// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.25;

interface IDAOFeeRegistry {
    error DAOFeeRegistry__FeeRecipientAlreadySet();
    error DAOFeeRegistry__InvalidFeeRecipient();
    error DAOFeeRegistry__InvalidFeeNumerator();
    error DAOFeeRegistry__InvalidRoleRegistry();
    error DAOFeeRegistry__InvalidCaller();

    event FeeRecipientSet(address indexed feeRecipient);
    event DefaultFeeNumeratorSet(uint256 defaultFeeNumerator);
    event RTokenFeeNumeratorSet(address indexed rToken, uint256 feeNumerator, bool isActive);

    function getFeeDetails(
        address rToken
    ) external view returns (address recipient, uint256 feeNumerator, uint256 feeDenominator);
}
