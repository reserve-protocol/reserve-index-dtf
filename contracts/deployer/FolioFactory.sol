// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { FolioProxyAdmin, FolioProxy } from "@deployer/FolioProxy.sol";

import { IFolioFactory } from "@interfaces/IFolioFactory.sol";
import { Versioned } from "@utils/Versioned.sol";
import { Folio, IFolio } from "@src/Folio.sol";

contract FolioFactory is IFolioFactory, Versioned {
    address public immutable daoFeeRegistry;
    address public immutable versionRegistry;

    address public immutable folioImplementation;

    constructor(address _daoFeeRegistry, address _versionRegistry) {
        daoFeeRegistry = _daoFeeRegistry;
        versionRegistry = _versionRegistry;

        folioImplementation = address(new Folio());
    }

    function createFolio(
        string memory name,
        string memory symbol,
        uint256 tradeDelay,
        uint256 auctionLength,
        address[] memory assets,
        uint256[] memory amounts,
        uint256 initShares,
        Folio.FeeRecipient[] memory feeRecipients,
        uint256 folioFee,
        address governor
    ) external returns (address) {
        if (assets.length != amounts.length) {
            revert FolioFactory__LengthMismatch();
        }

        if (assets.length == 0) {
            revert FolioFactory__EmptyAssets();
        }

        FolioProxyAdmin folioAdmin = new FolioProxyAdmin(governor, versionRegistry);
        Folio newFolio = Folio(address(new FolioProxy(folioImplementation, address(folioAdmin))));

        for (uint256 i; i < assets.length; i++) {
            SafeERC20.safeTransferFrom(IERC20(assets[i]), msg.sender, address(newFolio), amounts[i]);
        }

        IFolio.FolioBasicDetails memory basicDetails = IFolio.FolioBasicDetails({
            name: name,
            symbol: symbol,
            creator: msg.sender,
            governor: governor,
            assets: assets,
            initialShares: initShares
        });

        IFolio.FolioAdditionalDetails memory additionalDetails = IFolio.FolioAdditionalDetails({
            tradeDelay: tradeDelay,
            auctionLength: auctionLength,
            feeRegistry: daoFeeRegistry,
            feeRecipients: feeRecipients,
            folioFee: folioFee
        });

        newFolio.initialize(basicDetails, additionalDetails);

        emit FolioCreated(address(newFolio), address(folioAdmin));

        return address(newFolio);
    }
}
