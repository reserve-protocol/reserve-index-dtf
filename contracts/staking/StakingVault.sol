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

import { UD60x18, powu, ln } from "@prb/math/src/UD60x18.sol";

import "forge-std/console2.sol";

contract StakingVault is ERC4626, ERC20Permit, ERC20Votes, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private rewardTokens;
    uint256 public rewardRatio;

    struct RewardInfo {
        uint256 payoutLastPaid; // {s}
        uint256 rewardIndex;
        //
        uint256 balanceAccounted;
        uint256 balanceLastKnown;
        uint256 totalClaimed;
    }

    struct UserRewardInfo {
        uint256 lastRewardIndex;
        uint256 accruedRewards;
    }

    mapping(address token => RewardInfo rewardInfo) public rewardTrackers;
    mapping(address token => mapping(address user => UserRewardInfo userReward)) public userRewardTrackers;

    error Vault__InvalidRewardToken(address rewardToken);
    error Vault__RewardAlreadyRegistered();
    error Vault__RewardNotRegistered();

    constructor(
        string memory _name,
        string memory _symbol,
        IERC20 _underlying,
        address _initialOwner,
        uint256 rewardPeriod
    ) ERC4626(_underlying) ERC20(_name, _symbol) ERC20Permit(_name) Ownable(_initialOwner) {
        _setRewardRatio(rewardPeriod);
    }

    /**
     * Reward Management Logic
     */
    function addRewardToken(address _rewardToken) external onlyOwner {
        if (_rewardToken == address(this) || _rewardToken == asset()) {
            revert Vault__InvalidRewardToken(_rewardToken);
        }

        if (!rewardTokens.add(_rewardToken)) {
            revert Vault__RewardAlreadyRegistered();
        }

        RewardInfo storage rewardInfo = rewardTrackers[_rewardToken];

        rewardInfo.payoutLastPaid = block.timestamp;
        rewardInfo.balanceLastKnown = IERC20(_rewardToken).balanceOf(address(this));
        // @todo This changes based on if we are "ejecting" or not during remove and readd.
    }

    function removeRewardToken(address _rewardToken) external onlyOwner {
        if (!rewardTokens.remove(_rewardToken)) {
            revert Vault__RewardNotRegistered();
        }
    }

    function claimRewards(address[] calldata _rewardTokens) external accrueRewards(msg.sender, msg.sender) {
        for (uint256 i; i < _rewardTokens.length; i++) {
            address _rewardToken = _rewardTokens[i];

            RewardInfo storage rewardInfo = rewardTrackers[_rewardToken];
            UserRewardInfo storage userRewardTracker = userRewardTrackers[_rewardToken][msg.sender];

            uint256 claimableRewards = userRewardTracker.accruedRewards;

            userRewardTracker.accruedRewards = 0;
            rewardInfo.totalClaimed += claimableRewards;

            SafeERC20.safeTransfer(IERC20(_rewardToken), msg.sender, claimableRewards);
        }
    }

    /**
     * Reward Accrual Logic
     */
    function setRewardRatio(uint256 rewardHalfLife) external onlyOwner {
        _setRewardRatio(rewardHalfLife);
    }

    function _setRewardRatio(uint256 _rewardHalfLife) internal {
        // @todo sensible range for half life?
        // @todo this probably should also accrue rewards

        rewardRatio = UD60x18.unwrap(ln(UD60x18.wrap(2e18)) / UD60x18.wrap(_rewardHalfLife)) / 1e18;
    }

    function poke() external accrueRewards(msg.sender, msg.sender) {}

    modifier accrueRewards(address _caller, address _receiver) {
        uint256 supplyTokens = totalSupply();

        if (supplyTokens != 0) {
            console2.log("----------- accrue START");
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
            console2.log("----------- accrue END");
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
        uint256 tokensToHandout = (unaccountedBalance * handoutPercentage) / 1e18;

        uint256 supplyTokens = totalSupply();
        uint256 deltaIndex;

        if (supplyTokens != 0) {
            // {qRewardTok} = {qRewardTok} * {qShare} / {qShare}
            deltaIndex = (tokensToHandout * uint256(10 ** decimals())) / supplyTokens;

            console2.log("deltaIndex", deltaIndex);
        } else {
            // @todo Come back to this.
            // leftoverRewards[_rewardToken] += tokensToHandout;
        }

        // {qRewardTok} += {qRewardTok}
        rewardInfo.rewardIndex += deltaIndex;
        rewardInfo.payoutLastPaid = block.timestamp;
        rewardInfo.balanceAccounted += tokensToHandout;
        rewardInfo.balanceLastKnown = IERC20(_rewardToken).balanceOf(address(this)) + rewardInfo.totalClaimed;
    }

    function _accrueUser(address _user, address _rewardToken) internal {
        if (_user == address(0)) {
            return;
        }

        RewardInfo memory rewardInfo = rewardTrackers[_rewardToken];
        UserRewardInfo storage userRewardTracker = userRewardTrackers[_rewardToken][_user];

        uint256 deltaIndex = rewardInfo.rewardIndex - userRewardTracker.lastRewardIndex;

        // Accumulate rewards by multiplying user tokens by index and adding on unclaimed
        // {qRewardTok} = D18{qShare} * {qRewardTok} / D18{qShare}
        uint256 supplierDelta = (balanceOf(_user) * deltaIndex) / uint256(10 ** decimals());

        console2.log("supplierDelta", supplierDelta);

        // {qRewardTok} += {qRewardTok}
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

    function CLOCK_MODE() public view override returns (string memory) {
        return "mode=timestamp";
    }
}
