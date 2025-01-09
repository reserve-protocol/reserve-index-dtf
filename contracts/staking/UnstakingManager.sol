// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title UnstakingManager
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 */
contract UnstakingManager {
    IERC20 public immutable targetToken;
    IERC4626 public immutable vault;

    struct Lock {
        address user;
        uint256 amount; // {targetToken}
        uint256 unlockTime; // {s}
        uint256 claimedAt; // {s}
    }

    uint256 private nextLockId;
    mapping(uint256 => Lock) public locks;

    event LockCreated(uint256 lockId, address user, uint256 amount, uint256 unlockTime);
    event LockCancelled(uint256 lockId);
    event LockClaimed(uint256 lockId);

    error UnstakingManager__Unauthorized();
    error UnstakingManager__NotUnlockedYet();
    error UnstakingManager__AlreadyClaimed();

    constructor(IERC20 _asset) {
        targetToken = _asset;
        vault = IERC4626(msg.sender);
    }

    /// @param amount {targetToken}
    /// @param unlockTime {s}
    function createLock(address user, uint256 amount, uint256 unlockTime) external {
        require(msg.sender == address(vault), UnstakingManager__Unauthorized());

        SafeERC20.safeTransferFrom(targetToken, msg.sender, address(this), amount);

        uint256 lockId = nextLockId++;
        Lock storage lock = locks[lockId];

        lock.user = user;
        lock.amount = amount;
        lock.unlockTime = unlockTime;

        emit LockCreated(lockId, user, amount, unlockTime);
    }

    function cancelLock(uint256 lockId) external {
        Lock storage lock = locks[lockId];

        require(lock.user == msg.sender, UnstakingManager__Unauthorized());
        require(lock.claimedAt == 0, UnstakingManager__AlreadyClaimed());

        SafeERC20.forceApprove(targetToken, address(vault), lock.amount);
        vault.deposit(lock.amount, lock.user);

        emit LockCancelled(lockId);

        delete locks[lockId];
    }

    function claimLock(uint256 lockId) external {
        Lock storage lock = locks[lockId];

        require(lock.unlockTime <= block.timestamp && lock.unlockTime != 0, UnstakingManager__NotUnlockedYet());
        require(lock.claimedAt == 0, UnstakingManager__AlreadyClaimed());

        lock.claimedAt = block.timestamp;
        SafeERC20.safeTransfer(targetToken, lock.user, lock.amount);

        emit LockClaimed(lockId);
    }
}
