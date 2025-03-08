// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Folio } from "@src/Folio.sol";

contract FolioV2 is Folio {
    function version() public pure override returns (string memory) {
        return "10.0.0";
    }
}
