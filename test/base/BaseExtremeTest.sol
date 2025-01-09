// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./BaseTest.sol";
import { MAX_FOLIO_FEE, MAX_FEE_RECIPIENTS } from "@src/Folio.sol";

abstract contract BaseExtremeTest is BaseTest {
    struct MintRedeemTestParams {
        uint256 numTokens;
        uint8 decimals;
        uint256 amount;
    }

    struct TradingTestParams {
        uint8 sellDecimals;
        uint8 buyDecimals;
        uint256 sellAmount; // {sellTok}
        uint256 price; // D18{buyTok/sellTok}
    }

    struct FeeTestParams {
        uint256 amount;
        uint256 folioFee; // D18{1/s}
        uint256 daoFee; // D18{1}
        uint256 timeLapse; // {s}
        uint256 numFeeRecipients;
    }

    // Test dimensions
    uint8[] internal testDecimals = [6, 8, 18, 27];
    uint256[] internal testNumTokens = [1, 10, 50, 100, 500];
    uint256[] internal testAmounts = [1, 1e6, 1e18, 1e36];
    uint256[] internal testFolioFees = [0, MAX_FOLIO_FEE / 4, MAX_FOLIO_FEE / 2, MAX_FOLIO_FEE];
    uint256[] internal testDaoFees = [0, 0.01e18, 0.1e18, 0.15e18];
    uint256[] internal testTimeLapse = [1, 12, 1 days, 30 days, 120 days, YEAR_IN_SECONDS];
    uint256[] internal testNumFeeRecipients = [1, 5, 10, MAX_FEE_RECIPIENTS];

    MintRedeemTestParams[] internal mintRedeemTestParams;
    TradingTestParams[] internal tradingTestParams;
    FeeTestParams[] internal feeTestParams;

    function _testSetupBefore() public override {
        roleRegistry = new MockRoleRegistry();
        daoFeeRegistry = new FolioDAOFeeRegistry(IRoleRegistry(address(roleRegistry)), dao);
        versionRegistry = new FolioVersionRegistry(IRoleRegistry(address(roleRegistry)));
        folioDeployer = new FolioDeployer(address(daoFeeRegistry), address(versionRegistry), governanceDeployer);

        // register version
        versionRegistry.registerVersion(folioDeployer);

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
                    mintRedeemTestParams.push(
                        MintRedeemTestParams({
                            numTokens: testNumTokens[i],
                            decimals: testDecimals[j],
                            amount: testAmounts[k]
                        })
                    );
                    index++;
                }
            }
        }

        index = 0;
        for (uint256 i; i < testDecimals.length; i++) {
            for (uint256 j; j < testDecimals.length; j++) {
                for (uint256 k; k < testAmounts.length; k++) {
                    for (uint256 l; l < testAmounts.length; l++) {
                        tradingTestParams.push(
                            TradingTestParams({
                                sellDecimals: testDecimals[i],
                                buyDecimals: testDecimals[j],
                                sellAmount: testAmounts[k],
                                price: testAmounts[l]
                            })
                        );
                        index++;
                    }
                }
            }
        }

        index = 0;
        for (uint256 i; i < testAmounts.length; i++) {
            for (uint256 j; j < testFolioFees.length; j++) {
                for (uint256 k; k < testDaoFees.length; k++) {
                    for (uint256 l; l < testTimeLapse.length; l++) {
                        for (uint256 m; m < testNumFeeRecipients.length; m++) {
                            feeTestParams.push(
                                FeeTestParams({
                                    amount: testAmounts[i],
                                    folioFee: testFolioFees[j],
                                    daoFee: testDaoFees[k],
                                    timeLapse: testTimeLapse[l],
                                    numFeeRecipients: testNumFeeRecipients[m]
                                })
                            );
                            index++;
                        }
                    }
                }
            }
        }
    }
}
