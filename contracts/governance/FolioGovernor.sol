// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";

contract FolioGovernor is
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IVotes _token,
        TimelockControllerUpgradeable _timelock,
        uint48 _votingDelay, // {s}
        uint32 _votingPeriod, // {s}
        uint256 _proposalThreshold, // e.g. 0.01e18 for 1%
        uint256 quorumPercent // e.g 4 for 4%
    ) external initializer {
        __Governor_init("Reserve Folio Governor");
        __GovernorSettings_init(_votingDelay, _votingPeriod, _proposalThreshold);
        __GovernorVotes_init(_token);
        __GovernorVotesQuorumFraction_init(quorumPercent);
        __GovernorTimelockControl_init(_timelock);
    }

    function votingDelay() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingPeriod();
    }

    function quorum(
        uint256 blockNumber
    ) public view override(GovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable) returns (uint256) {
        return super.quorum(blockNumber);
    }

    function state(
        uint256 proposalId
    ) public view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(
        uint256 proposalId
    ) public view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        uint256 threshold = super.proposalThreshold(); // D18{1}
        uint256 pastSupply = token().getPastTotalSupply(clock() - 1);

        // CEIL to make sure thresholds near 0% don't get rounded down to 0 tokens
        return (threshold * pastSupply + (1e18 - 1)) / 1e18;
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }
}
