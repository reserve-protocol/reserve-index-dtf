// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "@interfaces/IFolio.sol";
import { IFolioDAOFeeRegistry } from "@interfaces/IFolioDAOFeeRegistry.sol";

import { D18, MAX_FEE_RECIPIENTS, MAX_TVL_FEE, MIN_MINT_FEE, ONE_OVER_YEAR } from "@utils/Constants.sol";
import { MathLib } from "@utils/MathLib.sol";

/**
 * @title FolioLib
 * @notice Library for Folio governance operations
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 */
library FolioLib {
    /// @dev Warning: An empty fee recipients table will result in all fees being sent to DAO
    function setFeeRecipients(
        IFolio.FeeRecipient[] storage feeRecipients,
        IFolio.FeeRecipient[] calldata _feeRecipients
    ) external {
        emit IFolio.FeeRecipientsSet(_feeRecipients);

        // Clear existing fee table
        uint256 len = feeRecipients.length;
        for (uint256 i; i < len; i++) {
            feeRecipients.pop();
        }

        // Add new items to the fee table
        len = _feeRecipients.length;

        if (len == 0) {
            return;
        }

        require(len <= MAX_FEE_RECIPIENTS, IFolio.Folio__TooManyFeeRecipients());

        address previousRecipient;
        uint256 total;

        for (uint256 i; i < len; i++) {
            require(_feeRecipients[i].recipient > previousRecipient, IFolio.Folio__FeeRecipientInvalidAddress());
            require(_feeRecipients[i].portion != 0, IFolio.Folio__FeeRecipientInvalidFeeShare());

            total += _feeRecipients[i].portion;
            previousRecipient = _feeRecipients[i].recipient;
            feeRecipients.push(_feeRecipients[i]);
        }

        // ensure table adds up to 100%
        require(total == D18, IFolio.Folio__BadFeeTotal());
    }

    /// @dev stack-too-deep
    struct FeeSharesParams {
        uint256 currentDaoPending; // {share}
        uint256 currentFeeRecipientsPending; // {share}
        uint256 tvlFee; // D18{1/s}
        uint256 folioFee; // D18{1} fraction of fee-recipient shares to burn
        uint256 supply; // {share}
        uint256 elapsed; // {s}
    }

    /// Compute TVL fee shares owed to the DAO and fee recipients
    /// @return _daoPendingFeeShares {share}
    /// @return _feeRecipientsPendingFeeShares {share}
    function computeFeeShares(
        FeeSharesParams calldata params,
        IFolioDAOFeeRegistry daoFeeRegistry
    ) external view returns (uint256 _daoPendingFeeShares, uint256 _feeRecipientsPendingFeeShares) {
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator, uint256 daoFeeFloor) = daoFeeRegistry.getFeeDetails(
            address(this)
        );

        // convert annual percentage to per-second for comparison with stored tvlFee
        // = 1 - (1 - feeFloor) ^ (1 / 31536000)
        // D18{1/s} = D18{1} - D18{1} * D18{1} ^ D18{1/s}
        uint256 feeFloor = D18 - MathLib.pow(D18 - daoFeeFloor, ONE_OVER_YEAR);

        // D18{1/s}
        uint256 _tvlFee = feeFloor > params.tvlFee ? feeFloor : params.tvlFee;

        // {share} += {share} * D18 / D18{1/s} ^ {s} - {share}
        uint256 feeShares = (params.supply * D18) / MathLib.powu(D18 - _tvlFee, params.elapsed) - params.supply;

        // D18{1} = D18{1/s} * D18 / D18{1/s}
        uint256 correction = (feeFloor * D18 + _tvlFee - 1) / _tvlFee;

        // {share} = {share} * D18{1} / D18
        uint256 daoShares = (correction > (daoFeeNumerator * D18 + daoFeeDenominator - 1) / daoFeeDenominator)
            ? (feeShares * correction + D18 - 1) / D18
            : (feeShares * daoFeeNumerator + daoFeeDenominator - 1) / daoFeeDenominator;

        _daoPendingFeeShares = params.currentDaoPending + daoShares;

        uint256 rawRecipientShares = feeShares - daoShares;
        uint256 selfShares = (rawRecipientShares * params.folioFee) / D18;
        _feeRecipientsPendingFeeShares = params.currentFeeRecipientsPending + rawRecipientShares - selfShares;
    }

    /// Set TVL fee by annual percentage. Different from how it is stored!
    /// @param _newFeeAnnually D18{1}
    /// @return _tvlFee D18{1/s} The computed per-second fee
    function setTVLFee(uint256 _newFeeAnnually) external returns (uint256 _tvlFee) {
        require(_newFeeAnnually <= MAX_TVL_FEE, IFolio.Folio__TVLFeeTooHigh());

        // convert annual percentage to per-second
        // = 1 - (1 - _newFeeAnnually) ^ (1 / 31536000)
        // D18{1/s} = D18{1} - D18{1} ^ {s}
        _tvlFee = D18 - MathLib.pow(D18 - _newFeeAnnually, ONE_OVER_YEAR);

        require(_newFeeAnnually == 0 || _tvlFee != 0, IFolio.Folio__TVLFeeTooLow());

        emit IFolio.TVLFeeSet(_tvlFee, _newFeeAnnually);
    }

    /// Compute mint fee shares for DAO and fee recipients
    /// @param shares {share} Amount of shares being minted
    /// @param _mintFee D18{1} Fee on mint
    /// @param _folioFee D18{1} Fraction of fee-recipient shares to burn
    /// @param minSharesOut {share} Minimum shares the caller must receive
    /// @param daoFeeRegistry The DAO fee registry to query fee details from
    /// @return sharesOut {share} Shares to mint for the receiver
    /// @return daoFeeShares {share} Shares owed to the DAO
    /// @return feeRecipientFeeShares {share} Shares owed to fee recipients (excludes self-fee shares)
    /// @dev stack-too-deep
    struct MintFeeParams {
        uint256 shares; // {share}
        uint256 mintFee; // D18{1}
        uint256 folioFee; // D18{1}
        uint256 minSharesOut; // {share}
    }

    function computeMintFees(
        MintFeeParams calldata params,
        IFolioDAOFeeRegistry daoFeeRegistry
    ) external view returns (uint256 sharesOut, uint256 daoFeeShares, uint256 feeRecipientFeeShares) {
        (, uint256 daoFeeNumerator, uint256 daoFeeDenominator, uint256 daoFeeFloor) = daoFeeRegistry.getFeeDetails(
            address(this)
        );

        // ensure DAO fee floor is at least 3 bps (set just above daily MAX_TVL_FEE)
        daoFeeFloor = daoFeeFloor > MIN_MINT_FEE ? daoFeeFloor : MIN_MINT_FEE;

        // {share} = {share} * D18{1} / D18
        uint256 totalFeeShares = (params.shares * params.mintFee + D18 - 1) / D18;
        daoFeeShares = (totalFeeShares * daoFeeNumerator + daoFeeDenominator - 1) / daoFeeDenominator;

        // ensure DAO's portion of fees is at least the DAO feeFloor
        uint256 minDaoShares = (params.shares * daoFeeFloor + D18 - 1) / D18;
        daoFeeShares = daoFeeShares < minDaoShares ? minDaoShares : daoFeeShares;

        // 100% to DAO, if necessary
        totalFeeShares = totalFeeShares < daoFeeShares ? daoFeeShares : totalFeeShares;

        // apply folioFee to recipient portion
        feeRecipientFeeShares = totalFeeShares - daoFeeShares;
        feeRecipientFeeShares -= (feeRecipientFeeShares * params.folioFee) / D18;

        // {share} minter pays the full fee (including self-fee shares that are burned)
        sharesOut = params.shares - totalFeeShares;
        require(sharesOut != 0 && sharesOut >= params.minSharesOut, IFolio.Folio__InsufficientSharesOut());
    }
}
