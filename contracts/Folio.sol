// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IFolioFeeRegistry } from "./interfaces/IFolioFeeRegistry.sol";
import { IFolio } from "./interfaces/IFolio.sol";
import { Versioned } from "./Versioned.sol";

// !!!! TODO !!!! REMOVE
import "forge-std/console2.sol";

uint256 constant MAX_FEE_NUMERATOR = 50_00;
uint256 constant FEE_DENOMINATOR = 100_00;

contract Folio is IFolio, ERC20, AccessControlEnumerable, Versioned {
    using EnumerableSet for EnumerableSet.AddressSet;

    IFolioFeeRegistry public daoFeeRegistry;

    /**
     * Roles
     */
    bytes32 constant PRICE_ORACLE = keccak256("PRICE_ORACLE");

    /**
     * Basket
     */
    bool public basketInitialized; // @audit Do we need this? Non-zero length basket should be enough
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

    constructor(
        string memory _name,
        string memory _symbol,
        FeeRecipient[] memory _feeRecipients,
        uint256 _folioFee,
        address _daoFeeRegistry,
        address _dutchTradeImplementation
    ) ERC20(_name, _symbol) {
        _setFeeRecipients(_feeRecipients);
        _setFolioFee(_folioFee);

        daoFeeRegistry = IFolioFeeRegistry(_daoFeeRegistry);
        dutchTradeImplementation = _dutchTradeImplementation;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function initialize(
        address[] memory _assets,
        address initializer,
        uint256 shares
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (basketInitialized) {
            revert Folio__BasketAlreadyInitialized();
        }

        uint256 assetLength = _assets.length;
        for (uint256 i; i < assetLength; i++) {
            if (_assets[i] == address(0)) {
                revert Folio__InvalidAsset();
            }

            uint256 assetBalance = IERC20(_assets[i]).balanceOf(address(this));
            if (assetBalance == 0) {
                revert Folio__InvalidAssetAmount(_assets[i], assetBalance);
            }

            basket.add(address(_assets[i]));
        }

        basketInitialized = true;

        _mint(initializer, shares);
    }

    function totalSupply() public view virtual override(ERC20) returns (uint256) {
        return super.totalSupply() + pendingFeeShares; // @audit This function should take time into consideration, both mint and redeem are wrong rn
    }

    // ({tokAddress}, {tok/share})
    function folio() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        return convertToAssets(1e18, Math.Rounding.Floor);
    }

    // {} -> ({tokAddress}, {tok})
    function totalAssets() external view returns (address[] memory _assets, uint256[] memory _amounts) {
        _assets = basket.values(); // @audit We need to limit the max basket size, otherwise this has unbounded gas cost

        uint256 assetLength = _assets.length;
        _amounts = new uint256[](assetLength);
        for (uint256 i; i < assetLength; i++) {
            _amounts[i] = IERC20(_assets[i]).balanceOf(address(this));
        }
    }

    // {share} -> ({tokAddress}, {tok})
    function convertToAssets(
        uint256 shares,
        Math.Rounding rounding // @audit TODO: Make explicit, should not be an external facing detail
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
        (_assets, _amounts) = convertToAssets(shares, Math.Rounding.Ceil); // @audit This should be Ceil if we want to protect the folio, Floor for min mints

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
        (_assets, _amounts) = convertToAssets(shares, Math.Rounding.Floor);

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
