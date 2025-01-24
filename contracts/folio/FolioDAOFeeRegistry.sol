// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "@interfaces/IFolio.sol";
import { IFolioDAOFeeRegistry } from "@interfaces/IFolioDAOFeeRegistry.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";

uint256 constant MAX_DAO_FEE = 0.5e18; // D18{1} 50%
uint256 constant MAX_FEE_FLOOR = 0.01e18; // D18{1} 1%
uint256 constant DEFAULT_FEE_FLOOR = 0.0015e18; // D18{1} 15 bps

/**
 * @title Folio
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice FolioDAOFeeRegistry tracks the DAO fees that should be applied to each Folio
 *         The DAO fee is the % of the Folio fees should go to the DAO.
 *         The fee floor is a lower-bound on the fees that can be charged to Folio users, in case
 *         the Folio has set its fees too low.
 */
contract FolioDAOFeeRegistry is IFolioDAOFeeRegistry {
    uint256 public constant FEE_DENOMINATOR = 1e18;

    IRoleRegistry public immutable roleRegistry;

    address private feeRecipient;
    uint256 private defaultFeeNumerator = MAX_DAO_FEE; // D18{1} fee starts at max

    mapping(address => uint256) private fTokenFeeNumerator; // D18{1}
    mapping(address => bool) private fTokenFeeSet;

    uint256 public defaultFeeFloor = DEFAULT_FEE_FLOOR; // D18{1} 15 bps
    mapping(address => uint256) private fTokenFeeFloor; // D18{1}
    mapping(address => bool) private fTokenFeeFloorSet;

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

        if (address(_feeRecipient) == address(0)) {
            revert FolioDAOFeeRegistry__InvalidFeeRecipient();
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

    /// @param feeNumerator_ {1} New default fee numerator
    function setDefaultFeeNumerator(uint256 feeNumerator_) external onlyOwner {
        if (feeNumerator_ > MAX_DAO_FEE) {
            revert FolioDAOFeeRegistry__InvalidFeeNumerator();
        }

        defaultFeeNumerator = feeNumerator_;
        emit DefaultFeeNumeratorSet(feeNumerator_);
    }

    function setTokenFeeNumerator(address fToken, uint256 feeNumerator_) external onlyOwner {
        if (feeNumerator_ > MAX_DAO_FEE) {
            revert FolioDAOFeeRegistry__InvalidFeeNumerator();
        }

        _setTokenFee(fToken, feeNumerator_, true);
    }

    function setDefaultFeeFloor(uint256 _defaultFeeFloor) external onlyOwner {
        if (_defaultFeeFloor > DEFAULT_FEE_FLOOR) {
            revert FolioDAOFeeRegistry__InvalidFeeFloor();
        }

        defaultFeeFloor = _defaultFeeFloor;
        emit DefaultFeeFloorSet(defaultFeeFloor);
    }

    function setTokenFeeFloor(address fToken, uint256 _feeFloor) external onlyOwner {
        if (_feeFloor > DEFAULT_FEE_FLOOR) {
            revert FolioDAOFeeRegistry__InvalidFeeFloor();
        }

        _setTokenFeeFloor(fToken, _feeFloor, true);
    }

    function resetTokenFees(address fToken) external onlyOwner {
        _setTokenFee(fToken, 0, false);
        _setTokenFeeFloor(fToken, 0, false);
    }

    /// @param feeNumerator D18{1}
    /// @param feeDenominator D18{1}
    function getFeeDetails(
        address fToken
    ) external view returns (address recipient, uint256 feeNumerator, uint256 feeDenominator, uint256 feeFloor) {
        recipient = feeRecipient;
        feeNumerator = fTokenFeeSet[fToken] ? fTokenFeeNumerator[fToken] : defaultFeeNumerator;
        feeDenominator = FEE_DENOMINATOR;
        feeFloor = fTokenFeeFloorSet[fToken]
            ? (defaultFeeFloor < fTokenFeeFloor[fToken] ? defaultFeeFloor : fTokenFeeFloor[fToken])
            : defaultFeeFloor;
    }

    // ==== Internal ====

    function _setTokenFee(address fToken, uint256 feeNumerator_, bool isActive) internal {
        IFolio(fToken).distributeFees();

        fTokenFeeNumerator[fToken] = feeNumerator_;
        fTokenFeeSet[fToken] = isActive;

        emit TokenFeeNumeratorSet(fToken, feeNumerator_, isActive);
    }

    function _setTokenFeeFloor(address fToken, uint256 feeFloor, bool isActive) internal {
        IFolio(fToken).distributeFees();

        fTokenFeeFloor[fToken] = feeFloor;
        fTokenFeeFloorSet[fToken] = isActive;

        emit TokenFeeFloorSet(fToken, feeFloor);
    }
}
