// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "@interfaces/IFolio.sol";
import { IFolioDAOFeeRegistry } from "@interfaces/IFolioDAOFeeRegistry.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";

uint256 constant MAX_DAO_FEE = 0.5e18; // D18{1} 50%

/**
 * @title Folio
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice FolioDAOFeeRegistry tracks the DAO fee that should be applied to each Folio
 */
contract FolioDAOFeeRegistry is IFolioDAOFeeRegistry {
    uint256 public constant FEE_DENOMINATOR = 1e18;

    IRoleRegistry public immutable roleRegistry;

    address private feeRecipient;
    uint256 private defaultFeeNumerator; // D18{1}

    mapping(address => uint256) private fTokenFeeNumerator; // D18{1}
    mapping(address => bool) private fTokenFeeSet;

    modifier onlyOwner() {
        require(roleRegistry.isOwner(msg.sender), FolioDAOFeeRegistry__InvalidCaller());
        _;
    }

    constructor(IRoleRegistry _roleRegistry, address _feeRecipient) {
        require(address(_roleRegistry) != address(0), FolioDAOFeeRegistry__InvalidRoleRegistry());
        require(address(_feeRecipient) != address(0), FolioDAOFeeRegistry__InvalidFeeRecipient());

        roleRegistry = _roleRegistry;
        feeRecipient = _feeRecipient;
        // defaultFeeNumerator = 0;
    }

    // === External ===

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        require(feeRecipient_ != address(0), FolioDAOFeeRegistry__InvalidFeeRecipient());
        require(feeRecipient_ != feeRecipient, FolioDAOFeeRegistry__FeeRecipientAlreadySet());

        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(feeRecipient_);
    }

    /// @param feeNumerator_ {1} New default fee numerator
    function setDefaultFeeNumerator(uint256 feeNumerator_) external onlyOwner {
        require(feeNumerator_ <= MAX_DAO_FEE, FolioDAOFeeRegistry__InvalidFeeNumerator());

        defaultFeeNumerator = feeNumerator_;
        emit DefaultFeeNumeratorSet(feeNumerator_);
    }

    function setTokenFeeNumerator(address fToken, uint256 feeNumerator_) external onlyOwner {
        require(feeNumerator_ <= MAX_DAO_FEE, FolioDAOFeeRegistry__InvalidFeeNumerator());

        _setTokenFee(fToken, feeNumerator_, true);
    }

    function resetTokenFee(address fToken) external onlyOwner {
        _setTokenFee(fToken, 0, false);
    }

    /// @param feeNumerator D18{1}
    /// @param feeDenominator D18{1}
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
