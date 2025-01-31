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

import { UD60x18 } from "@prb/math/src/UD60x18.sol";

import { UnstakingManager } from "./UnstakingManager.sol";

uint256 constant MAX_UNSTAKING_DELAY = 4 weeks; // {s}
uint256 constant MAX_REWARD_HALF_LIFE = 2 weeks; // {s}
uint256 constant MIN_REWARD_HALF_LIFE = 1 days; // {s}

uint256 constant LN_2 = 0.693147180559945309e18; // D18{1} ln(2e18)

uint256 constant SCALAR = 1e18; // D18

/**
 * @title StakingVault
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice StakingVault is a transferrable 1:1 wrapping of an underlying token that uses the ERC4626 interface.
 *         It earns the holder a claimable stream of multi rewards and enables them to vote in (external) governance.
 *         Unstaking is gated by a delay, implemented by an UnstakingManager.
 */
contract StakingVault is ERC4626, ERC20Permit, ERC20Votes, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private rewardTokens;
    uint256 public rewardRatio; // D18{1}

    UnstakingManager public immutable unstakingManager;
    uint256 public unstakingDelay; // {s}

    struct RewardInfo {
        uint256 payoutLastPaid; // {s}
        uint256 rewardIndex; // D18+decimals{reward/share}
        //
        uint256 balanceAccounted; // {reward}
        uint256 balanceLastKnown; // {reward}
        uint256 totalClaimed; // {reward}
    }

    struct UserRewardInfo {
        uint256 lastRewardIndex; // D18+decimals{reward/share}
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

    /// @param _name Name of the vault
    /// @param _symbol Symbol of the vault
    /// @param _underlying Underlying token deposited during staking
    /// @param _initialOwner Initial owner of the vault
    /// @param _rewardPeriod {s} Half life of the reward handout rate
    /// @param _unstakingDelay {s} Delay after unstaking before user receives their deposit
    constructor(
        string memory _name,
        string memory _symbol,
        IERC20 _underlying,
        address _initialOwner,
        uint256 _rewardPeriod,
        uint256 _unstakingDelay
    ) ERC4626(_underlying) ERC20(_name, _symbol) ERC20Permit(_name) Ownable(_initialOwner) {
        _setRewardRatio(_rewardPeriod);
        _setUnstakingDelay(_unstakingDelay);

        unstakingManager = new UnstakingManager(_underlying);
    }

    /**
     * Deposit & Delegate
     */
    function depositAndDelegate(uint256 assets) external returns (uint256 shares) {
        shares = deposit(assets, msg.sender);

        _delegate(msg.sender, msg.sender);
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

            SafeERC20.forceApprove(IERC20(asset()), address(unstakingManager), _assets);
            unstakingManager.createLock(_receiver, _assets, block.timestamp + unstakingDelay);

            emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
        }
    }

    /// @param _delay {s} New unstaking delay
    function setUnstakingDelay(uint256 _delay) external onlyOwner {
        _setUnstakingDelay(_delay);
    }

    /// @param _delay {s} New unstaking delay
    function _setUnstakingDelay(uint256 _delay) internal {
        require(_delay <= MAX_UNSTAKING_DELAY, Vault__InvalidUnstakingDelay());

        unstakingDelay = _delay;
        emit UnstakingDelaySet(_delay);
    }

    /**
     * Reward Management Logic
     */
    /// @param _rewardToken Reward token to add
    function addRewardToken(address _rewardToken) external onlyOwner {
        require(_rewardToken != address(this) && _rewardToken != asset(), Vault__InvalidRewardToken(_rewardToken));

        require(!disallowedRewardTokens[_rewardToken], Vault__DisallowedRewardToken(_rewardToken));

        require(rewardTokens.add(_rewardToken), Vault__RewardAlreadyRegistered());

        RewardInfo storage rewardInfo = rewardTrackers[_rewardToken];

        rewardInfo.payoutLastPaid = block.timestamp;
        rewardInfo.balanceLastKnown = IERC20(_rewardToken).balanceOf(address(this));

        emit RewardTokenAdded(_rewardToken);
    }

    /// @param _rewardToken Reward token to remove
    function removeRewardToken(address _rewardToken) external onlyOwner {
        disallowedRewardTokens[_rewardToken] = true;

        require(rewardTokens.remove(_rewardToken), Vault__RewardNotRegistered());

        emit RewardTokenRemoved(_rewardToken);
    }

    /// Allows to claim rewards
    /// Supports claiming accrued rewards for disallowed/removed tokens
    /// @param _rewardTokens Array of reward tokens to claim
    /// @return claimableRewards Amount claimed for each rewardToken
    function claimRewards(
        address[] calldata _rewardTokens
    ) external accrueRewards(msg.sender, msg.sender) returns (uint256[] memory claimableRewards) {
        claimableRewards = new uint256[](_rewardTokens.length);

        for (uint256 i; i < _rewardTokens.length; i++) {
            address _rewardToken = _rewardTokens[i];

            RewardInfo storage rewardInfo = rewardTrackers[_rewardToken];
            UserRewardInfo storage userRewardTracker = userRewardTrackers[_rewardToken][msg.sender];

            claimableRewards[i] = userRewardTracker.accruedRewards;

            if (claimableRewards[i] != 0) {
                // {reward} += {reward}
                rewardInfo.totalClaimed += claimableRewards[i];
                userRewardTracker.accruedRewards = 0;

                SafeERC20.safeTransfer(IERC20(_rewardToken), msg.sender, claimableRewards[i]);

                emit RewardsClaimed(msg.sender, _rewardToken, claimableRewards[i]);
            }
        }
    }

    function getAllRewardTokens() external view returns (address[] memory) {
        return rewardTokens.values();
    }

    /**
     * Reward Accrual Logic
     */
    /// @param rewardHalfLife {s}
    function setRewardRatio(uint256 rewardHalfLife) external onlyOwner {
        _setRewardRatio(rewardHalfLife);
    }

    /// @param _rewardHalfLife {s}
    function _setRewardRatio(uint256 _rewardHalfLife) internal accrueRewards(msg.sender, msg.sender) {
        require(
            _rewardHalfLife <= MAX_REWARD_HALF_LIFE && _rewardHalfLife >= MIN_REWARD_HALF_LIFE,
            Vault__InvalidRewardsHalfLife()
        );

        // D18{1/s} = D18{1} / {s}
        rewardRatio = LN_2 / _rewardHalfLife;

        emit RewardRatioSet(rewardRatio, _rewardHalfLife);
    }

    function poke() external accrueRewards(msg.sender, msg.sender) {}

    modifier accrueRewards(address _caller, address _receiver) {
        _accrueRewards(_caller, _receiver);
        _;
    }

    function _accrueRewards(address _caller, address _receiver) internal {
        address[] memory _rewardTokens = rewardTokens.values();
        uint256 _rewardTokensLength = _rewardTokens.length;

        for (uint256 i; i < _rewardTokensLength; i++) {
            address rewardToken = _rewardTokens[i];

            _accrueRewards(rewardToken);
            _accrueUser(_receiver, rewardToken);

            // If a deposit/withdraw operation gets called for another user we should
            // accrue for both of them to avoid potential issues
            // This is important for accruing for "from" and "to" in a transfer.
            if (_receiver != _caller) {
                _accrueUser(_caller, rewardToken);
            }
        }
    }

    function _accrueRewards(address _rewardToken) internal {
        RewardInfo storage rewardInfo = rewardTrackers[_rewardToken];

        uint256 balanceLastKnown = rewardInfo.balanceLastKnown;
        rewardInfo.balanceLastKnown = IERC20(_rewardToken).balanceOf(address(this)) + rewardInfo.totalClaimed;

        uint256 elapsed = block.timestamp - rewardInfo.payoutLastPaid;
        if (elapsed == 0) {
            return;
        }

        uint256 unaccountedBalance = balanceLastKnown - rewardInfo.balanceAccounted;
        uint256 handoutPercentage = 1e18 - UD60x18.wrap(1e18 - rewardRatio).powu(elapsed).unwrap() - 1; // rounds down

        // {reward} = {reward} * D18{1} / D18
        uint256 tokensToHandout = (unaccountedBalance * handoutPercentage) / 1e18;

        uint256 supplyTokens = totalSupply();

        if (supplyTokens != 0) {
            // D18+decimals{reward/share} = D18 * {reward} * decimals / {share}
            uint256 deltaIndex = (SCALAR * tokensToHandout * uint256(10 ** decimals())) / supplyTokens;

            // D18+decimals{reward/share} += D18+decimals{reward/share}
            rewardInfo.rewardIndex += deltaIndex;
            rewardInfo.balanceAccounted += tokensToHandout;
        }
        // @todo Add a test case for when supplyTokens is 0 for a while, the rewards are paid out correctly.

        rewardInfo.payoutLastPaid = block.timestamp;
    }

    function _accrueUser(address _user, address _rewardToken) internal {
        if (_user == address(0)) {
            return;
        }

        RewardInfo memory rewardInfo = rewardTrackers[_rewardToken];
        UserRewardInfo storage userRewardTracker = userRewardTrackers[_rewardToken][_user];

        // D18+decimals{reward/share}
        uint256 deltaIndex = rewardInfo.rewardIndex - userRewardTracker.lastRewardIndex;

        if (deltaIndex != 0) {
            // Accumulate rewards by multiplying user tokens by index and adding on unclaimed
            // {reward} = {share} * D18+decimals{reward/share} / decimals / D18
            uint256 supplierDelta = (balanceOf(_user) * deltaIndex) / uint256(10 ** decimals()) / SCALAR;

            // {reward} += {reward}
            userRewardTracker.accruedRewards += supplierDelta;
            userRewardTracker.lastRewardIndex = rewardInfo.rewardIndex;
        }
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
