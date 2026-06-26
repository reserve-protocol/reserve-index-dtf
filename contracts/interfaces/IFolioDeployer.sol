// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";

interface IFolioDeployer {
    error FolioDeployer__LengthMismatch();
    error FolioDeployer__InvalidStToken();

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
        bytes4[] optimisticSelectors;
        address[] optimisticProposers;
        address[] guardians;
        uint256 timelockDelay;
        uint256 proposalThrottleCapacity;
    }

    function folioImplementation() external view returns (address);
}
