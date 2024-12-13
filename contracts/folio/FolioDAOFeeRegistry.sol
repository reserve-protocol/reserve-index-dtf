// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "@interfaces/IFolio.sol";
import { IFolioDAOFeeRegistry } from "@interfaces/IFolioDAOFeeRegistry.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";

uint256 constant MAX_DAO_FEE = 0.15e18; // D18{1} 15%
uint256 constant FEE_DENOMINATOR = 1e18;

contract FolioDAOFeeRegistry is IFolioDAOFeeRegistry {
    IRoleRegistry public immutable roleRegistry;

    address private feeRecipient;
    uint256 private defaultFeeNumerator; // 0%

    mapping(address => uint256) private fTokenFeeNumerator;
    mapping(address => bool) private fTokenFeeSet;

    modifier onlyOwner() {
        if (!roleRegistry.isOwner(msg.sender)) {
            revert FolioDAOFeeRegistry__InvalidCaller();
        }
        _;
    }

    constructor(IRoleRegistry _roleRegistry, address _feeRecipient) {
        if (address(_roleRegistry) == address(0)) {
            revert FolioDAOFeeRegistry__InvalidRoleRegistry();
        }

        roleRegistry = _roleRegistry;
        feeRecipient = _feeRecipient;
    }

    // === External ===

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) {
            revert FolioDAOFeeRegistry__InvalidFeeRecipient();
        }
        if (feeRecipient_ == feeRecipient) {
            revert FolioDAOFeeRegistry__FeeRecipientAlreadySet();
        }

        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(feeRecipient_);
    }

    function setDefaultFeeNumerator(uint256 feeNumerator_) external onlyOwner {
        if (feeNumerator_ > MAX_DAO_FEE) {
            revert FolioDAOFeeRegistry__InvalidFeeNumerator();
        }

        defaultFeeNumerator = feeNumerator_;
        emit DefaultFeeNumeratorSet(defaultFeeNumerator);
    }

    function setTokenFeeNumerator(address fToken, uint256 feeNumerator_) external onlyOwner {
        if (feeNumerator_ > MAX_DAO_FEE) {
            revert FolioDAOFeeRegistry__InvalidFeeNumerator();
        }

        _setTokenFee(fToken, feeNumerator_, true);
    }

    function resetTokenFee(address fToken) external onlyOwner {
        _setTokenFee(fToken, 0, false);
    }

    function getFeeDetails(
        address fToken
    ) external view returns (address recipient, uint256 feeNumerator, uint256 feeDenominator) {
        recipient = feeRecipient;
        feeNumerator = fTokenFeeSet[fToken] ? fTokenFeeNumerator[fToken] : defaultFeeNumerator;
        feeDenominator = FEE_DENOMINATOR;
    }

    // ==== Internal ====

    function _setTokenFee(address fToken, uint256 feeNumerator_, bool isActive) internal {
        IFolio(fToken).distributeFees(); // @audit review

        fTokenFeeNumerator[fToken] = feeNumerator_;
        fTokenFeeSet[fToken] = isActive;

        emit TokenFeeNumeratorSet(fToken, feeNumerator_, isActive);
    }
}
