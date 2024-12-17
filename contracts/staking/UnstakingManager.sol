// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract UnstakingManager {
    IERC20 immutable targetToken;

    struct Lock {
        address user;
        uint256 amount;
        uint256 unlockTime;
        uint256 claimedAt;
    }

    uint256 nextLockId;
    mapping(uint256 => Lock) public locks;

    // @todo Expand events
    event LockCreated(uint256 lockId);
    event LockClaimed(uint256 lockId);

    error UnstakingManager__Unauthorized();
    error UnstakingManager__NotUnlockedYet();
    error UnstakingManager__AlreadyClaimed();

    constructor(IERC20 _asset) {
        targetToken = _asset;
    }

    function createLock(address user, uint256 amount, uint256 unlockTime) external {
        SafeERC20.safeTransferFrom(targetToken, msg.sender, address(this), amount);

        uint256 lockId = nextLockId++;
        Lock storage lock = locks[lockId];

        lock.user = user;
        lock.amount = amount;
        lock.unlockTime = unlockTime;

        emit LockCreated(lockId);
    }

    function claimLock(uint256 lockId) external {
        Lock storage lock = locks[lockId];

        require(lock.user == msg.sender, UnstakingManager__Unauthorized());
        require(lock.unlockTime <= block.timestamp, UnstakingManager__NotUnlockedYet());
        require(lock.claimedAt == 0, UnstakingManager__AlreadyClaimed());

        lock.claimedAt = block.timestamp;
        SafeERC20.safeTransfer(targetToken, lock.user, lock.amount);

        emit LockClaimed(lockId);
    }
}
