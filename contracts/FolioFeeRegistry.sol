// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "./interfaces/IFolio.sol";
import { IFolioFeeRegistry } from "./interfaces/IFolioFeeRegistry.sol";

uint256 constant MAX_FEE_NUMERATOR = 15_00; // Max DAO Fee: 15%
uint256 constant FEE_DENOMINATOR = 100_00;

interface IRoleRegistry {
    function isOwner(address account) external view returns (bool);
}

contract FolioFeeRegistry is IFolioFeeRegistry {
    IRoleRegistry public immutable roleRegistry;

    address private feeRecipient;
    uint256 private defaultFeeNumerator; // 0%

    mapping(address => uint256) private fTokenFeeNumerator;
    mapping(address => bool) private fTokenFeeSet;

    modifier onlyOwner() {
        if (!roleRegistry.isOwner(msg.sender)) {
            revert FolioFeeRegistry__InvalidCaller();
        }
        _;
    }

    constructor(IRoleRegistry _roleRegistry, address _feeRecipient) {
        if (address(_roleRegistry) == address(0)) {
            revert FolioFeeRegistry__InvalidRoleRegistry();
        }

        roleRegistry = _roleRegistry;
        feeRecipient = _feeRecipient;
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) {
            revert FolioFeeRegistry__InvalidFeeRecipient();
        }
        if (feeRecipient_ == feeRecipient) {
            revert FolioFeeRegistry__FeeRecipientAlreadySet();
        }

        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(feeRecipient_);
    }

    function setDefaultFeeNumerator(uint256 feeNumerator_) external onlyOwner {
        if (feeNumerator_ > MAX_FEE_NUMERATOR) {
            revert FolioFeeRegistry__InvalidFeeNumerator();
        }

        defaultFeeNumerator = feeNumerator_;
        emit DefaultFeeNumeratorSet(defaultFeeNumerator);
    }

    /// @dev A fee below 1% not recommended due to poor precision in the Distributor
    function setTokenFeeNumerator(address fToken, uint256 feeNumerator_) external onlyOwner {
        if (feeNumerator_ > MAX_FEE_NUMERATOR) {
            revert FolioFeeRegistry__InvalidFeeNumerator();
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

    /**
     * Internal Functions
     */
    function _setTokenFee(address fToken, uint256 feeNumerator_, bool isActive) internal {
        IFolio(fToken).distributeFees(); // @audit review

        fTokenFeeNumerator[fToken] = feeNumerator_;
        fTokenFeeSet[fToken] = isActive;

        emit TokenFeeNumeratorSet(fToken, feeNumerator_, isActive);
    }
}
