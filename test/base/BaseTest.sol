// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MockERC20 } from "utils/MockERC20.sol";
import { MockERC20 } from "utils/MockERC20.sol";
import { MockRoleRegistry } from "utils/MockRoleRegistry.sol";
import { MockBidder } from "utils/MockBidder.sol";

import { IFolio, Folio } from "@src/Folio.sol";
import { FolioDeployer } from "@folio/FolioDeployer.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { FolioVersionRegistry } from "@folio/FolioVersionRegistry.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { GovernanceDeployer } from "@gov/GovernanceDeployer.sol";
import { IRoleRegistry, FolioDAOFeeRegistry } from "@folio/FolioDAOFeeRegistry.sol";

abstract contract BaseTest is Script, Test {
    // === Auth roles ===
    bytes32 constant OWNER = keccak256("OWNER");
    bytes32 constant PRICE_ORACLE = keccak256("PRICE_ORACLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    uint256 constant D6_TOKEN_1 = 1e6;
    uint256 constant D6_TOKEN_10K = 1e10; // 1e4 = 10K tokens with 6 decimals
    uint256 constant D6_TOKEN_100K = 1e11; // 1e5 = 100K tokens with 6 decimals
    uint256 constant D6_TOKEN_1M = 1e12; // 1e5 = 100K tokens with 6 decimals
    uint256 constant D18_TOKEN_1 = 1e18;
    uint256 constant D18_TOKEN_10K = 1e22; // 1e4 = 10K tokens with 18 decimals
    uint256 constant D18_TOKEN_100K = 1e23; // 1e5 = 100K tokens with 18 decimals
    uint256 constant D18_TOKEN_1M = 1e24; // 1e6 = 1M tokens with 18 decimals
    uint256 constant D27_TOKEN_1 = 1e27;
    uint256 constant D27_TOKEN_10K = 1e31; // 1e4 = 10K tokens with 27 decimals
    uint256 constant D27_TOKEN_100K = 1e32; // 1e5 = 100K tokens with 27 decimals
    uint256 constant D27_TOKEN_1M = 1e33; // 1e6 = 1M tokens with 27 decimals

    uint256 constant YEAR_IN_SECONDS = 31536000;

    address priceCurator = 0x00000000000000000000000000000000000000cc; // has PRICE_CURATOR
    address dao = 0xDA00000000000000000000000000000000000000; // has TRADE_PROPOSER
    address owner = 0xCc00000000000000000000000000000000000000; // has DEFAULT_ADMIN_ROLE
    address user1 = 0xfF00000000000000000000000000000000000000;
    address user2 = 0xbb00000000000000000000000000000000000000;
    address feeReceiver = 0xdD00000000000000000000000000000000000000;
    IERC20 USDC;
    IERC20 DAI;
    IERC20 MEME;
    IERC20 USDT; // not in basket

    Folio folio;
    FolioDeployer folioDeployer;
    FolioDAOFeeRegistry daoFeeRegistry;
    FolioVersionRegistry versionRegistry;
    FolioProxyAdmin proxyAdmin;
    MockRoleRegistry roleRegistry;

    GovernanceDeployer governanceDeployer;

    address governorImplementation;
    address timelockImplementation;

    function setUp() public {
        _testSetup();
        // _setUp();
    }

    /// @dev Implement this if you want a custom configured deployment
    function _setUp() public virtual {}

    /// @dev Note that most permissions are given to owner
    function _testSetup() public virtual {
        _testSetupBefore();
        _coreSetup();
        _testSetupAfter();
    }

    function _coreSetup() public {}

    function _testSetupBefore() public virtual {
        roleRegistry = new MockRoleRegistry();
        daoFeeRegistry = new FolioDAOFeeRegistry(IRoleRegistry(address(roleRegistry)), dao);
        versionRegistry = new FolioVersionRegistry(IRoleRegistry(address(roleRegistry)));

        governorImplementation = address(new FolioGovernor());
        timelockImplementation = address(new TimelockControllerUpgradeable());
        governanceDeployer = new GovernanceDeployer(governorImplementation, timelockImplementation);
        folioDeployer = new FolioDeployer(address(daoFeeRegistry), address(versionRegistry), governanceDeployer);

        // register version
        versionRegistry.registerVersion(folioDeployer);

        deployCoins();
        mintTokens();
        vm.warp(100);
        vm.roll(1);
    }

    function _testSetupAfter() public virtual {
        vm.label(address(priceCurator), "Price Curator");
        vm.label(address(dao), "DAO");
        vm.label(address(owner), "Owner");
        vm.label(address(user1), "User 1");
        vm.label(address(user2), "User 2");
        vm.label(address(USDC), "USDC");
        vm.label(address(DAI), "DAI");
        vm.label(address(MEME), "MEME");
        vm.label(address(USDT), "USDT");
    }

    function _forkSetupAfter() public {}

    function deployCoins() public {
        USDC = IERC20(new MockERC20("USDC", "USDC", 6));
        DAI = IERC20(new MockERC20("DAI", "DAI", 18));
        MEME = new MockERC20("MEME", "MEME", 27);
        USDT = new MockERC20("USDT", "USDT", 6);
    }

    function mintTokens() public {
        address[] memory actors = new address[](4);
        actors[0] = owner;
        actors[1] = user1;
        actors[2] = user2;
        actors[3] = address(this);
        uint256[] memory amounts_6 = new uint256[](4);
        amounts_6[0] = D6_TOKEN_1M;
        amounts_6[1] = D6_TOKEN_1M;
        amounts_6[2] = D6_TOKEN_1M;
        amounts_6[3] = D6_TOKEN_1M;
        uint256[] memory amounts_18 = new uint256[](4);
        amounts_18[0] = D18_TOKEN_1M;
        amounts_18[1] = D18_TOKEN_1M;
        amounts_18[2] = D18_TOKEN_1M;
        amounts_18[3] = D18_TOKEN_1M;
        uint256[] memory amounts_27 = new uint256[](4);
        amounts_27[0] = D27_TOKEN_1M;
        amounts_27[1] = D27_TOKEN_1M;
        amounts_27[2] = D27_TOKEN_1M;
        amounts_27[3] = D27_TOKEN_1M;

        mintToken(address(USDC), actors, amounts_6);
        mintToken(address(DAI), actors, amounts_18);
        mintToken(address(MEME), actors, amounts_27);
        mintToken(address(USDT), actors, amounts_6);

        uint256[] memory amounts_eth = new uint256[](4);
        amounts_eth[0] = 10 ether;
        amounts_eth[1] = 10 ether;
        amounts_eth[2] = 10 ether;
        amounts_eth[3] = 10 ether;
        dealETH(actors, amounts_eth);
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

    // === Internal ===

    function createFolio(
        address[] memory _assets,
        uint256[] memory _amounts,
        uint256 _initialShares,
        uint256 _tradeDelay,
        uint256 _auctionLength,
        IFolio.FeeRecipient[] memory _feeRecipients,
        uint256 _folioFee,
        uint256 _mintingFee,
        address _owner,
        address _tradeProposer,
        address _priceCurator
    ) internal returns (Folio, FolioProxyAdmin) {
        IFolio.FolioBasicDetails memory _basicDetails = IFolio.FolioBasicDetails({
            name: "Test Folio",
            symbol: "TFOLIO",
            assets: _assets,
            amounts: _amounts,
            initialShares: _initialShares
        });

        IFolio.FolioAdditionalDetails memory _additionalDetails = IFolio.FolioAdditionalDetails({
            tradeDelay: _tradeDelay,
            auctionLength: _auctionLength,
            feeRecipients: _feeRecipients,
            folioFee: _folioFee,
            mintingFee: _mintingFee
        });

        address[] memory _tradeProposers = new address[](1);
        _tradeProposers[0] = _tradeProposer;
        address[] memory _priceCurators = new address[](1);
        _priceCurators[0] = _priceCurator;

        (address _folio, address _proxyAdmin) = folioDeployer.deployFolio(
            _basicDetails,
            _additionalDetails,
            _owner,
            _tradeProposers,
            _priceCurators,
            new address[](0)
        );

        return (Folio(_folio), FolioProxyAdmin(_proxyAdmin));
    }
}
