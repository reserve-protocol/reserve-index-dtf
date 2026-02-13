// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";
import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";

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

    struct GovParams {
        IReserveOptimisticGovernor.OptimisticGovernanceParams optimisticParams;
        IReserveOptimisticGovernor.StandardGovernanceParams standardParams;
        IOptimisticSelectorRegistry.SelectorData[] optimisticSelectorData;
        address[] optimisticProposers;
        address[] guardians;
        uint256 timelockDelay;
        address underlying;
    }

    function folioImplementation() external view returns (address);
}
