# Certora Formal Verification

This folder contains the formal verification specifications for the Reserve Folio protocol using the Certora Prover.

## Folder Structure

```
certora/
├── confs/                        # Configuration files for running the prover
│   ├── properties/*.conf           # Main configuration files
│   └── folio_prerequisities.conf   # Configuration file for invariants assumed in the main rules
├── harnesses/                    # Solidity harness contracts for verification
│   ├── FolioHarness.sol            # Folio harness exposing internal functions, introducing helper functions
│   ├── InterpolatePriceHarness.sol # Contract exposing RebalancingLibHarness.InterpolatePrice
│   └── RebalancingLibHarness.sol   # Contract for introducing rerouting summaries
├── mocks/                        # Solidity mocks
│   ├── MockTrustedFiller.sol       # Mock for the trustedFiller contract
├── patches/                      # Patch files
│   ├── Folio.patch                 # Patch file changing visibility of private variables to internal
├── requirements.txt              # Pinned Python dependencies for the local prover frontend
├── scripts/                      # Scripts to build and run the local Certora Prover
│   ├── setup-local-prover.sh       # Installs the pinned open-source prover toolchain
│   ├── run-prover.sh               # Runs one local prover configuration
│   ├── run-with-patch.sh           # Applies Folio.patch and always restores the source tree
│   ├── P*.sh                       # Run scripts for various properties
│   ├── run-all.sh                  # Runs all properties
└── specs/                        # CVL specification files
    ├── summaries-Folio.spec        # Math summaries
    ├── folio-prerequisities.spec   # Spec file with invariants used in the main rules
    ├── folio-assumptions.spec      # Spec file introducing assumptions for the rules
    ├── folio-methods-common.spec   # Spec file listing Folio methods
    ├── folio-*.spec                # Spec files for main properties
    └── Summaries/                  # Spec files containing function summaries
```

## Verified properties

### P-01 Token to share ratio does not decrease

Outside of bid/trustedFill flow, the token to share ratio does not decrease for each underlying token unless fees are applied.

### P-02 Share value does not decrease

If prices are set correctly, share value does not decrease (includes the bid flow).

### P-03 Auction limit is not exceeded

Bid cannot exceed the auction limit. Trusted fill can exceed this value by obtaining more tokens than would be expected through bid.

### P-04 Bid flow is equivalent to trustedFill flow

If trusted fill behaves correctly, Folio always gets the same or more via trustedFill flow than via bid. Same restrictions on token limits are used.

### P-05 Only tokens in surplus or deficit can be traded

Tokens already within desired limits cannot be traded.

### P-06 `_price()` monotonically decreases throughout the auction

Assuming exp function is monotonic, the `_price` function is non-increasing with time.

### P-07 Splitting bids is equivalent to one bid

Splitting one larger bid into two can change bidAmount by at most 1 wei due to rounding. This rounding is in favour of the Folio.

### P-08 Only mint, redeem and fees can change share quantities

### P-09 We can sell tokens via bid only if they are in surplus, we can buy tokens only if they are in deficit. We cannot create deficit nor surplus via bid.

### P-10 Tokens can be removed from the basket by admin or if their balance is 0.

## Prerequisites

The proof uses the GPLv3 [open-source Certora Prover](https://github.com/Certora/CertoraProver) locally. It does not install the hosted `certora-cli` package, submit jobs to Certora's servers, or require a `CERTORAKEY`.

The automated setup supports Debian-based Linux x86_64 and requires `curl`, `dpkg-deb`, `git`, Python 3, `tar`, and `unzip`. It downloads checksum-pinned JDK, Rust, Z3, CVC4, CVC5, Yices, `psmisc`, and Solidity toolchains, then builds CertoraProver 8.9.0 from its pinned source commit into the ignored `.certora/` directory.

```bash
pnpm install --frozen-lockfile
./certora/scripts/setup-local-prover.sh
```

The initial source build takes several minutes. Later setup calls return immediately. On other platforms, install the [upstream CertoraProver dependencies](https://github.com/Certora/CertoraProver#dependencies), build release 8.9.0 with `./gradlew copy-assets`, and run the local `certoraRun.py` against these configuration files.

## Running the Prover

Run one property with its convenience script:

```bash
./certora/scripts/P6.sh
```

The property scripts apply `certora/patches/Folio.patch`, run all configurations for that property, and restore `contracts/Folio.sol` even if the prover fails or is interrupted. To run a specific configuration with the same cleanup behavior:

```bash
./certora/scripts/run-with-patch.sh certora/confs/properties/P6-2.conf
```

Run the complete suite with:

```bash
./certora/scripts/run-all.sh
```

Results are written locally to `emv-*-certora-*/Reports/`. No proof data leaves the machine.

### Documentation

For more information on the Certora Prover and CVL specification language, see:

- [Open-source Certora Prover](https://github.com/Certora/CertoraProver)
- [Certora Documentation](https://docs.certora.com/)
- [CVL Language Reference](https://docs.certora.com/en/latest/docs/cvl/index.html)
