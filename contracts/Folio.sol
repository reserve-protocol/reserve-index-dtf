// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Versioned } from "@utils/Versioned.sol";

import { IFolioFeeRegistry } from "./interfaces/IFolioFeeRegistry.sol";
import { IFolio } from "./interfaces/IFolio.sol";

// !!!! TODO !!!! REMOVE
import "forge-std/console2.sol";

uint256 constant MAX_FEE_NUMERATOR = 50_00;
uint256 constant FEE_DENOMINATOR = 100_00;

contract Folio is IFolio, Initializable, ERC20Upgradeable, AccessControlEnumerableUpgradeable, Versioned {
    using EnumerableSet for EnumerableSet.AddressSet;

    IFolioFeeRegistry public daoFeeRegistry;

    /**
     * Roles
     */
    bytes32 constant PRICE_ORACLE = keccak256("PRICE_ORACLE");
    bytes32 constant CHIEF_VIBES_OFFICER = keccak256("CHIEF_VIBES_OFFICER");

    /**
     * Basket
     */
    EnumerableSet.AddressSet private basket;

    /**
     * Fees
     */
    FeeRecipient[] public feeRecipients;
    uint256 public folioFee; // of FEE_DENOMINATOR

    /**
     * System
     */
    uint256 public lastPoke; // {s}
    uint256 public pendingFeeShares;

    address public dutchTradeImplementation;
    uint256 public dutchAuctionLength; // {s}

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _name,
        string memory _symbol,
        address _dutchTradeImplementation,
        address _daoFeeRegistry,
        FeeRecipient[] memory _feeRecipients,
        uint256 _folioFee,
        address[] memory _assets,
        address creator,
        uint256 shares,
        address governor
    ) external initializer {
        __ERC20_init(_name, _symbol);
        __AccessControlEnumerable_init();
        __AccessControl_init();

        _setFeeRecipients(_feeRecipients);
        _setFolioFee(_folioFee);

        dutchTradeImplementation = _dutchTradeImplementation;
        daoFeeRegistry = IFolioFeeRegistry(_daoFeeRegistry);

        uint256 assetLength = _assets.length;
        for (uint256 i; i < assetLength; i++) {
            if (_assets[i] == address(0)) {
                revert Folio__InvalidAsset();
            }

            uint256 assetBalance = IERC20(_assets[i]).balanceOf(address(this));
            if (assetBalance == 0) {
                revert Folio__InvalidAssetAmount(_assets[i]);
            }

            basket.add(address(_assets[i]));
        }

        _mint(creator, shares);
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
    }

    function totalSupply() public view virtual override(ERC20Upgradeable) returns (uint256) {
        return super.totalSupply() + pendingFeeShares; // @audit This function should take time into consideration, both mint and redeem are wrong rn
    }

    // ({tokAddress}, {tok/share})
    function folio() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        return toAssets(10 ** decimals(), Math.Rounding.Floor);
    }

    // {} -> ({tokAddress}, {tok})
    function totalAssets() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        _assets = basket.values();

        uint256 assetLength = _assets.length;
        _amounts = new uint256[](assetLength);
        for (uint256 i; i < assetLength; i++) {
            _amounts[i] = IERC20(_assets[i]).balanceOf(address(this));
        }
    }

    // {share} -> ({tokAddress}, {tok})
    function toAssets(
        uint256 shares,
        Math.Rounding rounding
    ) public view returns (address[] memory _assets, uint256[] memory _amounts) {
        _assets = basket.values();

        uint256 len = _assets.length;
        _amounts = new uint256[](len);
        for (uint256 i; i < len; i++) {
            uint256 assetBal = IERC20(_assets[i]).balanceOf(address(this));

            _amounts[i] = Math.mulDiv(shares, assetBal, totalSupply(), rounding);
        }
    }

    // {share} -> ({tokAddress}, {tok})
    function mint(
        uint256 shares,
        address receiver
    ) external returns (address[] memory _assets, uint256[] memory _amounts) {
        (_assets, _amounts) = toAssets(shares, Math.Rounding.Ceil); // @audit This should be Ceil if we want to protect the folio, Floor for min mints

        uint256 assetLength = _assets.length;
        for (uint256 i; i < assetLength; i++) {
            SafeERC20.safeTransferFrom(IERC20(_assets[i]), msg.sender, address(this), _amounts[i]);
        }

        _mint(receiver, shares);
    }

    // {share} -> ({tokAddress}, {tok})
    function redeem(
        uint256 shares,
        address receiver
    ) external returns (address[] memory _assets, uint256[] memory _amounts) {
        (_assets, _amounts) = toAssets(shares, Math.Rounding.Floor);

        _burn(msg.sender, shares);

        uint256 len = _assets.length;
        for (uint256 i; i < len; i++) {
            SafeERC20.safeTransfer(IERC20(_assets[i]), receiver, _amounts[i]);
        }
    }

    /**
     * Fee Management
     */
    function setFolioFee(uint256 _newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setFolioFee(_newFee);
    }

    function setFeeRecipients(FeeRecipient[] memory _newRecipients) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributeFees();

        _setFeeRecipients(_newRecipients);
    }

    function distributeFees() public {
        _poke();
        // @audit TODO: Come back to this one.

        // collect dao fee off the top
        (address recipient, uint256 daoFeeNumerator, uint256 daoFeeDenominator) = daoFeeRegistry.getFeeDetails(
            address(this)
        );
        uint256 daoFee = (pendingFeeShares * daoFeeNumerator) / daoFeeDenominator;
        _mint(recipient, daoFee);
        pendingFeeShares -= daoFee;

        // distribute the rest of the demurrage fee
        uint256 len = feeRecipients.length;
        for (uint256 i; i < len; i++) {
            uint256 fee = (pendingFeeShares * feeRecipients[i].share) / FEE_DENOMINATOR;

            _mint(feeRecipients[i].recipient, fee);
        }

        pendingFeeShares = 0;
    }

    function poke() external {
        _poke();
    }

    function getPendingFeeShares() public view returns (uint256) {
        return pendingFeeShares + _getPendingFeeShares();
    }

    /**
     * Internal Functions
     */
    function _getPendingFeeShares() internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 timeDelta = block.timestamp - lastPoke;

        return ((supply * (folioFee * timeDelta)) / 365 days) / FEE_DENOMINATOR;
    }

    function _poke() internal {
        if (lastPoke == block.timestamp) {
            return;
        }

        pendingFeeShares += _getPendingFeeShares();
        lastPoke = block.timestamp;
    }

    function _setFolioFee(uint256 _newFee) internal {
        if (_newFee > MAX_FEE_NUMERATOR) {
            revert Folio__FeeTooHigh();
        }

        folioFee = _newFee;
    }

    function _setFeeRecipients(FeeRecipient[] memory _feeRecipients) internal {
        // Clear existing fee table
        uint256 len = feeRecipients.length;
        for (uint256 i; i < len; i++) {
            feeRecipients.pop();
        }

        // Add new items to the fee table
        uint256 total;
        len = _feeRecipients.length;
        for (uint256 i; i < len; i++) {
            if (_feeRecipients[i].recipient == address(0)) {
                revert Folio__FeeRecipientInvalidAddress();
            }

            if (_feeRecipients[i].share == 0) {
                revert Folio__FeeRecipientInvalidFeeShare();
            }

            total += _feeRecipients[i].share;
            feeRecipients.push(_feeRecipients[i]);
        }

        if (total != FEE_DENOMINATOR) {
            revert Folio__BadFeeTotal();
        }
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        _poke();

        super._update(from, to, value);
    }
}
