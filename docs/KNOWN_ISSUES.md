# Known Issues and Accepted Design Limitations

This document records behavior that is known and intentionally retained in the current protocol design. It describes the implementation pinned by this repository; it does not describe a future mitigation.

## Optimistic veto threshold includes undelegated supply

**Status:** Known issue; intended design.

`ReserveOptimisticGovernor.state()` calculates an optimistic proposal's veto threshold from the staking vault's past total share supply. That supply includes shares whose holders have not configured optimistic delegation. By contrast, `againstVotes` can only be cast using optimistically delegated voting weight.

The denominator and numerator therefore cover different token sets. A sufficiently large amount of undelegated staking-vault shares can increase the veto threshold beyond the optimistic voting weight available at the proposal snapshot. In that situation, token holders cannot make the proposal reach `Defeated`, so the proposal does not automatically transition to a confirmation vote. If it is not otherwise cancelled, it becomes `Succeeded` after the veto period and the approved optimistic calls can execute without the standard timelock delay.

This behavior is accepted as part of the optimistic-governance trust model. It does not permit arbitrary execution:

- optimistic proposals may only use target and selector pairs registered in `OptimisticSelectorRegistry`;
- the registry rejects the staking vault, governor, timelock, and registry itself as targets; and
- the Guardian retains `CANCELLER_ROLE` and can cancel a pending optimistic proposal manually.

Operationally, staking-vault holders who intend to participate in vetoes must configure optimistic delegation before the proposal snapshot. Governance operators and the Guardian should monitor total share supply relative to optimistically delegated voting weight during veto windows and use Guardian cancellation when the onchain veto threshold is not practically reachable.
