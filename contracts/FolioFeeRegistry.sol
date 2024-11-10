// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.25;

import { IFolio } from "./interfaces/IFolio.sol";
import { RoleRegistry } from "./RoleRegistry.sol";
import { IFolioFeeRegistry } from "./interfaces/IFolioFeeRegistry.sol";

uint256 constant MAX_FEE_NUMERATOR = 15_00; // Max DAO Fee: 15%
uint256 constant FEE_DENOMINATOR = 100_00;

contract FolioFeeRegistry is IFolioFeeRegistry {
    RoleRegistry public roleRegistry;

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

    constructor(RoleRegistry _roleRegistry, address _feeRecipient) {
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
    function setRTokenFeeNumerator(address fToken, uint256 feeNumerator_) external onlyOwner {
        if (feeNumerator_ > MAX_FEE_NUMERATOR) {
            revert FolioFeeRegistry__InvalidFeeNumerator();
        }
        _setFTokenFee(fToken, feeNumerator_, true);
    }

    function resetRTokenFee(address fToken) external onlyOwner {
        _setFTokenFee(fToken, 0, false);
    }

    function getFeeDetails(
        address fToken
    ) external view returns (address recipient, uint256 feeNumerator, uint256 feeDenominator) {
        recipient = feeRecipient;
        feeNumerator = fTokenFeeSet[fToken] ? fTokenFeeNumerator[fToken] : defaultFeeNumerator;
        feeDenominator = FEE_DENOMINATOR;
    }

    function registerSelf() external {
        if (fTokenFeeSet[msg.sender]) {
            revert FolioFeeRegistry__RTokenAlreadySet();
        }
        fTokenFeeSet[msg.sender] = true;
        fTokenFeeNumerator[msg.sender] = defaultFeeNumerator;
    }

    /*
        Internal functions
    */
    function _setFTokenFee(address fToken, uint256 feeNumerator_, bool isActive) internal {
        IFolio(fToken).distributeFees();

        fTokenFeeNumerator[fToken] = feeNumerator_;
        fTokenFeeSet[fToken] = isActive;
        emit RTokenFeeNumeratorSet(fToken, feeNumerator_, isActive);
    }
}
