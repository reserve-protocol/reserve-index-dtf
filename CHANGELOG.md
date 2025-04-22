## Release 3.0.0

This release adds the following features:

- **Trusted Fillers**: The Folio is now integrated with [Trusted Fillers](https://github.com/reserve-protocol/trusted-fillers/) and can be enabled by governance to allow async fillers to compete in auctions to provide better prices. All auction limitations still apply to these fillers. Currently, the only supported async filler is CoW Swap.

- **Rebalance Targets**: Rebalancing for Folios is now managed via a rebalance target. The rebalancing target is a set of tokens and their respective weights that the Folio would aim to achieve. Only one rebalance can be active at a time, and the `AUCTION_APPROVER` role has become the `REBALANCE_MANAGER` role. The trading governance can set the target rebalance along with parameters such as known prices and limits. Note that the Folio itself remains unchained, and claims to the tokens remains pro-rata during mint and redeem.

- **Auctions Overhaul**: With the new rebalancing target, the auction system has been overhauled. Auctions can now be started based on the token targets in the rebalance target, while the `AUCTION_LAUNCHER` can provide more up-to-date prices to improve the rebalancing performance.

- **Supply Inflation Change**: Folio used to inflate the total supply every block, starting with this version the fee inflation is accounted for every 24 hours. There is no performance impact to this change, this is equivalent to the previous behavior, but it allows for more flexibility in the future.

Additionally, the following features have been deprecated:

- **Auction Approver**: The `AUCTION_APPROVER` role has been deprecated and replaced with the `REBALANCE_MANAGER` role.

- **Dust Limits**: The dust limits have been deprecated and replaced with the new rebalancing target system.

## Release 2.0.0

This release adds the following features:

- **Repeatable Auctions**: Governance can now specify the number of times an auction can be repeated while approving the auctions. This allows the auctions to be started up to the specified number of times until the other parameters are fulfilled, and the lot available in the auction is exhausted.

- **Dust Limits**: Governance can now specify the minimum amount of tokens that would be considered "valuable" for the folio and disallow removing those tokens from the basket for any reason. These dust limits are also used to limit actions in auctions and other places where amount of tokens are important. Both the admin and rebalance managers can set these limits.

- **Minimum Mint Enforcement**: While minting Folio tokens, you can now specify a minimum amount out such that any changes to fees between you sending the transaction and inclusion would cause it to revert. The output amount must also be non-zero going forward.

## Release 1.0.0

Initial Release.
