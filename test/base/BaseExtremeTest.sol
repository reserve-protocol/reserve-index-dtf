// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "utils/MockERC20.sol";

import { Folio } from "contracts/Folio.sol";
import { FolioFactory } from "contracts/FolioFactory.sol";
import { FolioFeeRegistry } from "contracts/FolioFeeRegistry.sol";
import { RoleRegistry } from "contracts/RoleRegistry.sol";

abstract contract BaseExtremeTest is Script, Test {
    uint256 constant YEAR_IN_SECONDS = 31536000;

    address dao = 0xDA00000000000000000000000000000000000000;
    address owner = 0xfF00000000000000000000000000000000000000;
    address user1 = 0xaa00000000000000000000000000000000000000;
    address user2 = 0xbb00000000000000000000000000000000000000;
    address feeReceiver = 0xCc00000000000000000000000000000000000000;

    Folio folio;
    FolioFactory folioFactory;
    FolioFeeRegistry daoFeeRegistry;
    RoleRegistry roleRegistry;

    struct TestParam {
        uint256 numTokens;
        uint8 decimals;
        uint256 amount;
    }

    // Test dimensions
    uint8[] internal testDecimals = [6, 8, 18, 27];
    uint256[] internal testNumTokens = [1, 2, 4, 10, 100, 500];
    uint256[] internal testAmounts = [1, 10, 1e4, 1e6, 1e12];

    TestParam[] internal testParameters;

    function setUp() public {
        _testSetup();
        // _setUp();
    }

    /// @dev Implement this if you want a custom configured deployment
    function _setUp() public virtual {}

    /// @dev Note that most permissions are given to owner
    function _testSetup() public {
        _testSetupBefore();
        _coreSetup();
        _testSetupAfter();
    }

    function _coreSetup() public {}

    function _testSetupBefore() public {
        roleRegistry = new RoleRegistry();
        daoFeeRegistry = new FolioFeeRegistry(roleRegistry, dao);
        folioFactory = new FolioFactory(address(daoFeeRegistry), address(0));
        _processParameters();
    }

    function _testSetupAfter() public {
        vm.label(address(dao), "DAO");
        vm.label(address(owner), "Owner");
        vm.label(address(user1), "User 1");
        vm.label(address(user2), "User 2");
    }

    function _forkSetupAfter() public {}

    function deployCoin(string memory _name, string memory _symbol, uint8 _decimals) public returns (IERC20) {
        return IERC20(new MockERC20(_name, _symbol, _decimals));
    }

    function mintTokens(address _token, address[] memory _accounts, uint256 amount) public {
        uint256[] memory amounts = new uint256[](_accounts.length);
        uint256[] memory amounts_eth = new uint256[](_accounts.length);

        for (uint256 i; i < _accounts.length; i++) {
            amounts[i] = amount;
            amounts_eth[i] = 10 ether;
        }

        mintToken(_token, _accounts, amounts);
        dealETH(_accounts, amounts_eth);
    }

    function mintToken(address _token, address[] memory _accounts, uint256[] memory _amounts) public {
        for (uint256 i = 0; i < _amounts.length; i++) {
            deal(address(_token), _accounts[i], _amounts[i], true);
        }
    }

    function dealETH(address[] memory _accounts, uint256[] memory _amounts) public {
        for (uint256 i = 0; i < _accounts.length; i++) {
            vm.deal(_accounts[i], _amounts[i]);
        }
    }

    function getActors() public view returns (address[] memory) {
        address[] memory actors = new address[](4);
        actors[0] = owner;
        actors[1] = user1;
        actors[2] = user2;
        actors[3] = address(this);
        return actors;
    }

    function _processParameters() public {
        uint256 index = 0;
        for (uint256 i; i < testNumTokens.length; i++) {
            for (uint8 j; j < testDecimals.length; j++) {
                for (uint256 k; k < testAmounts.length; k++) {
                    testParameters.push(
                        TestParam({ numTokens: testNumTokens[i], decimals: testDecimals[j], amount: testAmounts[k] })
                    );
                    index++;
                }
            }
        }
    }
}
