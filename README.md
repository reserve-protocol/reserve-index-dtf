# Reserve Folio

## Overview

The Reserve Folio protocol is a platform for creating and managing portfolios of onchain, ERC20-compliant assets. These assets are unpriced by the protocol, and instead rely on an active Pricing Oracle role to provide prices when initiating auctions.

## Architecture

TODO

## Testing

- unit test all basic functionality in isolation, using mocks where necessary
  - Folio.sol
  - FolioDutchTrade.sol
- integration test all core functionality, using mocks where necessary
  - Folio.sol + FolioDutchTrade.sol
- fork test all core functionality using invariants
  - mainnet, base, (arbitrum?, optimism?)
- extreme test all core functionality (parameters and units at the extreme ends of what the protocol accepts)
  - token decimals (esp with high unit bias)
  - basket sizes
  - demurrage
  - price oracle trade prices
