# Certora Formal Verification

This folder contains the formal verification specifications for the Reserve Folio protocol using the Certora Prover.

## Folder Structure

```
certora/
├── conf/                         # Configuration files for running the prover
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
├── scripts/                      # Scripts to apply patches and run certora prover
│   ├── apply-patch.sh              # Applies the Folio.patch using git apply
│   ├── remove-patch.sh             # Removes the application of the Folio.patch
│   ├── P*.sh                       # Run scripts for various properties
│   ├── run-all.sh                  # Runs all properties
└── spec/                         # CVL specification files
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

### P-06 _price() monotonically decreases throughout the auction
Assuming exp function is monotonic, the _price function is non-increasing with time.

### P-07 Splitting bids is equivalent to one bid
Splitting one larger bid into two can change bidAmount by at most 1 wei due to rounding. This rounding is in favour of the Folio.

### P-08 Only mint, redeem and fees can change share quantities

### P-09 We can sell tokens via bid only if they are in surplus, we can buy tokens only if they are in deficit. We cannot create deficit nor surplus via bid.

### P-10 Tokens can be removed from the basket by admin or if their balance is 0.



## Prerequisites

1. Install the Certora Prover CLI:
   ```bash
   pip install certora-cli
   ```

2. Set your Certora API key:
   ```bash
   export CERTORAKEY=<your-api-key>
   ```



## Running the Prover

It is possible to run the configurations directly via

```bash
certoraRun certora/confs/properties/<config_file>.conf
```

this assumes that the patch file is already applied. For convenience, you can use the run scripts for each property which will apply the patch, run the Certora prover and then remove the patch. Some properties will run multiple conf files and thus create multiple jobs.
You can also run all properties:

```bash
./certora/scripts/run-all.sh
```



### Documentation
For more information on the Certora Prover and CVL specification language, see:
- [Certora Documentation](https://docs.certora.com/)
- [CVL Language Reference](https://docs.certora.com/en/latest/docs/cvl/index.html)
- [Certora Prover CLI](https://docs.certora.com/en/latest/docs/prover/cli/index.html)
