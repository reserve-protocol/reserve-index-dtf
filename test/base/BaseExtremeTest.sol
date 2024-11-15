// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./BaseTest.sol";

abstract contract BaseExtremeTest is BaseTest {
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

    function _testSetupBefore() public override {
        roleRegistry = new RoleRegistry();
        daoFeeRegistry = new FolioFeeRegistry(roleRegistry, dao);
        folioFactory = new FolioFactory(address(daoFeeRegistry), address(0));
        _processParameters();
    }

    function _testSetupAfter() public override {
        vm.label(address(dao), "DAO");
        vm.label(address(owner), "Owner");
        vm.label(address(user1), "User 1");
        vm.label(address(user2), "User 2");
    }

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
