// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolio } from "@interfaces/IFolio.sol";

import { D18, MAX_FEE_RECIPIENTS } from "@utils/Constants.sol";

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
}
