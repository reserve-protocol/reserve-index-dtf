// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";

import { UD60x18, powu } from "@prb/math/src/UD60x18.sol";

import { UnstakingManager } from "./UnstakingManager.sol";

uint256 constant MAX_UNSTAKING_DELAY = 4 weeks; // {s}
uint256 constant MAX_REWARD_HALF_LIFE = 2 weeks; // {s}

uint256 constant LN_2 = 0.693147180559945309e18; // D18{1} ln(2e18)

uint256 constant SCALAR = 1e18; // D18

/**
 * @title StakingVault
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 */
contract StakingVault is ERC4626, ERC20Permit, ERC20Votes, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private rewardTokens;
    uint256 public rewardRatio; // D18{1}

    UnstakingManager public immutable unstakingManager;
    uint256 public unstakingDelay;

    struct RewardInfo {
        uint256 payoutLastPaid; // {s}
        uint256 rewardIndex; // D18{reward}
        //
        uint256 balanceAccounted; // {reward}
        uint256 balanceLastKnown; // {reward}
        uint256 totalClaimed; // {reward}
    }

    struct UserRewardInfo {
        uint256 lastRewardIndex; // D18{reward}
        uint256 accruedRewards; // {reward}
    }

    mapping(address token => RewardInfo rewardInfo) public rewardTrackers;
    mapping(address token => bool isDisallowed) public disallowedRewardTokens;
    mapping(address token => mapping(address user => UserRewardInfo userReward)) public userRewardTrackers;

    error Vault__InvalidRewardToken(address rewardToken);
    error Vault__DisallowedRewardToken(address rewardToken);
    error Vault__RewardAlreadyRegistered();
    error Vault__RewardNotRegistered();
    error Vault__InvalidUnstakingDelay();
    error Vault__InvalidRewardsHalfLife();

    event UnstakingDelaySet(uint256 delay);
    event RewardTokenAdded(address rewardToken);
    event RewardTokenRemoved(address rewardToken);
    event RewardsClaimed(address user, address rewardToken, uint256 amount);
    event RewardRatioSet(uint256 rewardRatio, uint256 halfLife);

    constructor(
        string memory _name,
        string memory _symbol,
        IERC20 _underlying,
        address _initialOwner,
        uint256 rewardPeriod,
        uint256 _unstakingDelay
    ) ERC4626(_underlying) ERC20(_name, _symbol) ERC20Permit(_name) Ownable(_initialOwner) {
        _setRewardRatio(rewardPeriod);
        _setUnstakingDelay(_unstakingDelay);

        unstakingManager = new UnstakingManager(_underlying);
    }

    /**
     * Withdraw Logic
     */
    function _withdraw(
        address _caller,
        address _receiver,
        address _owner,
        uint256 _assets,
        uint256 _shares
    ) internal override {
        if (unstakingDelay == 0) {
            super._withdraw(_caller, _receiver, _owner, _assets, _shares);
        } else {
            // Since we can't use the builtin `_withdraw`, we need to take care of the entire flow here.
            if (_caller != _owner) {
                _spendAllowance(_owner, _caller, _shares);
            }

            // Burn the shares first.
            _burn(_owner, _shares);

            IERC20(asset()).approve(address(unstakingManager), _assets);
            unstakingManager.createLock(_receiver, _assets, block.timestamp + unstakingDelay);

            emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
        }
    }

    function setUnstakingDelay(uint256 _delay) external onlyOwner {
        _setUnstakingDelay(_delay);
    }

    function _setUnstakingDelay(uint256 _delay) internal {
        if (_delay > MAX_UNSTAKING_DELAY) {
            revert Vault__InvalidUnstakingDelay();
        }

        unstakingDelay = _delay;

        emit UnstakingDelaySet(_delay);
    }

    /**
     * Reward Management Logic
     */
    function addRewardToken(address _rewardToken) external onlyOwner {
        if (_rewardToken == address(this) || _rewardToken == asset()) {
            revert Vault__InvalidRewardToken(_rewardToken);
        }

        if (disallowedRewardTokens[_rewardToken]) {
            revert Vault__DisallowedRewardToken(_rewardToken);
        }

        if (!rewardTokens.add(_rewardToken)) {
            revert Vault__RewardAlreadyRegistered();
        }

        RewardInfo storage rewardInfo = rewardTrackers[_rewardToken];

        rewardInfo.payoutLastPaid = block.timestamp;
        rewardInfo.balanceLastKnown = IERC20(_rewardToken).balanceOf(address(this));

        emit RewardTokenAdded(_rewardToken);
    }

    function removeRewardToken(address _rewardToken) external onlyOwner {
        disallowedRewardTokens[_rewardToken] = true;

        if (!rewardTokens.remove(_rewardToken)) {
            revert Vault__RewardNotRegistered();
        }

        delete rewardTrackers[_rewardToken];

        emit RewardTokenRemoved(_rewardToken);
    }

    function claimRewards(address[] calldata _rewardTokens) external accrueRewards(msg.sender, msg.sender) {
        for (uint256 i; i < _rewardTokens.length; i++) {
            address _rewardToken = _rewardTokens[i];

            RewardInfo storage rewardInfo = rewardTrackers[_rewardToken];
            UserRewardInfo storage userRewardTracker = userRewardTrackers[_rewardToken][msg.sender];

            uint256 claimableRewards = userRewardTracker.accruedRewards;

            // {reward} += {reward}
            rewardInfo.totalClaimed += claimableRewards;
            userRewardTracker.accruedRewards = 0;

            if (claimableRewards != 0) {
                SafeERC20.safeTransfer(IERC20(_rewardToken), msg.sender, claimableRewards);
            }

            emit RewardsClaimed(msg.sender, _rewardToken, claimableRewards);
        }
    }

    function getAllRewardTokens() external view returns (address[] memory) {
        return rewardTokens.values();
    }

    /**
     * Reward Accrual Logic
     */
    function setRewardRatio(uint256 rewardHalfLife) external onlyOwner {
        _setRewardRatio(rewardHalfLife);
    }

    function _setRewardRatio(uint256 _rewardHalfLife) internal accrueRewards(msg.sender, msg.sender) {
        if (_rewardHalfLife > MAX_REWARD_HALF_LIFE) {
            revert Vault__InvalidRewardsHalfLife();
        }

        // D18{1/s} = D18{1} / {s}
        rewardRatio = LN_2 / _rewardHalfLife;

        emit RewardRatioSet(rewardRatio, _rewardHalfLife);
    }

    function poke() external accrueRewards(msg.sender, msg.sender) {}

    modifier accrueRewards(address _caller, address _receiver) {
        address[] memory _rewardTokens = rewardTokens.values();
        uint256 _rewardTokensLength = _rewardTokens.length;

        for (uint256 i; i < _rewardTokensLength; i++) {
            address rewardToken = _rewardTokens[i];

            _accrueRewards(rewardToken);
            _accrueUser(_receiver, rewardToken);

            // If a deposit/withdraw operation gets called for another user we should
            // accrue for both of them to avoid potential issues
            if (_receiver != _caller) {
                _accrueUser(_caller, rewardToken);
            }
        }
        _;
    }

    function _accrueRewards(address _rewardToken) internal {
        RewardInfo storage rewardInfo = rewardTrackers[_rewardToken];

        uint256 elapsed = block.timestamp - rewardInfo.payoutLastPaid;
        if (elapsed == 0) {
            return;
        }

        uint256 unaccountedBalance = rewardInfo.balanceLastKnown - rewardInfo.balanceAccounted;
        uint256 handoutPercentage = 1e18 - UD60x18.wrap(1e18 - rewardRatio).powu(elapsed).unwrap();

        // {reward} = {reward} * D18{1} / D18
        uint256 tokensToHandout = (unaccountedBalance * handoutPercentage) / 1e18;

        uint256 supplyTokens = totalSupply();

        if (supplyTokens != 0) {
            // D18{reward} = D18 * {reward} * {share} / {share}
            uint256 deltaIndex = (SCALAR * tokensToHandout * uint256(10 ** decimals())) / supplyTokens;

            // D18{reward} += D18{reward}
            rewardInfo.rewardIndex += deltaIndex;
            rewardInfo.balanceAccounted += tokensToHandout;
        }
        // @todo Add a test case for when supplyTokens is 0 for a while, the reward are paid out correctly.

        // {reward} = {reward} + {reward}
        rewardInfo.balanceLastKnown = IERC20(_rewardToken).balanceOf(address(this)) + rewardInfo.totalClaimed;
        rewardInfo.payoutLastPaid = block.timestamp;
    }

    function _accrueUser(address _user, address _rewardToken) internal {
        if (_user == address(0)) {
            return;
        }

        RewardInfo memory rewardInfo = rewardTrackers[_rewardToken];
        UserRewardInfo storage userRewardTracker = userRewardTrackers[_rewardToken][_user];

        // D18{reward}
        uint256 deltaIndex = rewardInfo.rewardIndex - userRewardTracker.lastRewardIndex;

        // Accumulate rewards by multiplying user tokens by index and adding on unclaimed
        // {reward} = {share} * D18{reward} / {share} / D18
        uint256 supplierDelta = (balanceOf(_user) * deltaIndex) / uint256(10 ** decimals()) / SCALAR;

        // {reward} += {reward}
        userRewardTracker.accruedRewards += supplierDelta;
        userRewardTracker.lastRewardIndex = rewardInfo.rewardIndex;
    }

    /**
     * Overrides
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) accrueRewards(from, to) {
        super._update(from, to, value);
    }

    function nonces(address _owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(_owner);
    }

    function decimals() public view virtual override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    /**
     * ERC5805 Clock
     */
    function clock() public view override returns (uint48) {
        return Time.timestamp();
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}
