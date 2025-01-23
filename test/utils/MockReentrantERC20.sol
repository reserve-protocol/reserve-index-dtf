// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

interface IFolioMock {
    function toAssets(uint256 shares, Math.Rounding rounding) external returns (address[] memory, uint256[] memory);
}

/// @dev MockReentrantERC20 contract for testing use only
contract MockReentrantERC20 is ERC20 {
    uint8 private _decimals;
    bool private reentrancyEnabled;

    constructor(string memory name_, string memory symbol_, uint256 decimals_) ERC20(name_, symbol_) {
        _decimals = uint8(decimals_);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function setReentrancy(bool enabled) external {
        reentrancyEnabled = enabled;
    }

    // mock call
    function _update(address from, address to, uint256 value) internal override(ERC20) {
        if (reentrancyEnabled) IFolioMock(msg.sender).toAssets(1e18, Math.Rounding.Floor); // reentrant call
        super._update(from, to, value);
    }
}
