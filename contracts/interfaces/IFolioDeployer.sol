// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFolioDeployer {
    error FolioDeployer__LengthMismatch();

    event FolioDeployed(address indexed folioOwner, address indexed folio, address folioAdmin);
    event GovernedFolioDeployed(
        address indexed stToken,
        address indexed folio,
        address ownerGovernor,
        address ownerTimelock,
        address tradingGovernor,
        address tradingTimelock
    );

    struct GovRoles {
        address[] existingBasketManagers;
        address[] auctionLaunchers;
        address[] brandManagers;
    }

    function folioImplementation() external view returns (address);
}
