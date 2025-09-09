// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "@interfaces/IFolio.sol";
import { IFolioDAOFeeRegistry } from "@interfaces/IFolioDAOFeeRegistry.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";

/**
 * @title Folio
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice FolioDAOFeeRegistry tracks the DAO fees that should be applied to each Folio
 *         The DAO fee is the % of the Folio fees should go to the DAO.
 *         The fee floor is a lower-bound on what can be charged to Folio users, in case
 *         the Folio has set its own top-level fees too low.
 *
 *         For example, if the DAO fee is 50%, and the fee floor is 0.15%, then any tvl fee
 *         that is less than 0.30% will result in the DAO receiving 0.15% and the folo beneficiaries receiving
 *         the tvl fee minus 0.15%. At <=0.15% tvl fee, the DAO receives 0.15% and folio beneficiaries receive 0%
 */
contract FolioDAOFeeRegistry is IFolioDAOFeeRegistry {
    uint256 public constant FEE_DENOMINATOR = 1e18;

    uint256 private immutable MAX_DAO_FEE;
    uint256 private immutable MAX_FEE_FLOOR;

    IRoleRegistry public immutable roleRegistry;

    address private feeRecipient;
    uint256 private defaultFeeNumerator; // D18{1} starts at max, set in constructor

    mapping(address => uint256) private fTokenFeeNumerator; // D18{1}
    mapping(address => bool) private fTokenFeeSet;

    uint256 public defaultFeeFloor; // D18{1} starts at max, set in constructor
    mapping(address => uint256) private fTokenFeeFloor; // D18{1}
    mapping(address => bool) private fTokenFeeFloorSet;

    modifier onlyOwner() {
        require(roleRegistry.isOwner(msg.sender), FolioDAOFeeRegistry__InvalidCaller());
        _;
    }

    constructor(IRoleRegistry _roleRegistry, address _feeRecipient) {
        require(address(_roleRegistry) != address(0), FolioDAOFeeRegistry__InvalidRoleRegistry());
        require(address(_feeRecipient) != address(0), FolioDAOFeeRegistry__InvalidFeeRecipient());

        roleRegistry = _roleRegistry;
        feeRecipient = _feeRecipient;

        (MAX_DAO_FEE, MAX_FEE_FLOOR) = _maxFees();
        defaultFeeNumerator = MAX_DAO_FEE;
        defaultFeeFloor = MAX_FEE_FLOOR;
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

    function setDefaultFeeFloor(uint256 _defaultFeeFloor) external onlyOwner {
        require(_defaultFeeFloor <= MAX_FEE_FLOOR, FolioDAOFeeRegistry__InvalidFeeFloor());

        defaultFeeFloor = _defaultFeeFloor;
        emit DefaultFeeFloorSet(defaultFeeFloor);
    }

    function setTokenFeeFloor(address fToken, uint256 _feeFloor) external onlyOwner {
        require(_feeFloor <= defaultFeeFloor, FolioDAOFeeRegistry__InvalidFeeFloor());

        _setTokenFeeFloor(fToken, _feeFloor, true);
    }

    function resetTokenFees(address fToken) external onlyOwner {
        _setTokenFee(fToken, 0, false);
        _setTokenFeeFloor(fToken, 0, false);
    }

    /// @return recipient
    /// @return feeNumerator D18{1}
    /// @return feeDenominator D18{1}
    /// @return feeFloor D18{1}
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

        emit TokenFeeFloorSet(fToken, feeFloor, isActive);
    }

    /// Chain-specific maximum fees
    /// @return D18{1} Maximum DAO fee (platform fee)
    /// @return D18{1} Maximum fee floor
    function _maxFees() internal view returns (uint256, uint256) {
        // mainnet: 50%, 15 bps
        if (block.chainid == 1) {
            return (0.5e18, 0.0015e18);
        }

        // base: 50%, 15 bps
        if (block.chainid == 8453) {
            return (0.5e18, 0.0015e18);
        }

        // bsc: 33.33%, 10 bps
        if (block.chainid == 56) {
            return (uint256(1e18) / 3, 0.001e18);
        }

        // default: 50%, 15 bps
        return (0.5e18, 0.0015e18);
    }
}
