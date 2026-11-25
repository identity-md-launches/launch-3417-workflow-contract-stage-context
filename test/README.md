# Offline contract tests

The suite tests the approved `LaunchToken` / `DonationVault` pairing with the
repository's pinned Solidity 0.8.26 compiler. The real token supplies every balance
used by the integration and invariant tests through ordinary transfers. There are
no storage edits, token-balance cheatcodes, forks, RPC URLs, or network dependencies
in those tests.

Run the combined suite with the verifier's seed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x9e9dbb18f92a78de9adcdfdac3fb6e4441fb001bb12de4a98ff08c49f7ee2cb9 forge test
```

During the bounded assignment, build artifacts can stay in the disposable test area:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache FOUNDRY_FUZZ_SEED=0x9e9dbb18f92a78de9adcdfdac3fb6e4441fb001bb12de4a98ff08c49f7ee2cb9 forge test
```

## Added coverage

| Test file | Behaviors checked |
| --- | --- |
| `DonationVaultAdversarial.t.sol` | False, reverted, short and noncanonical boolean responses; successful transfers without return data; full rollback of token effects and allowance; zero receipt; fees on deposits; missing token code; retry and unrelated-gift liveness; reentry from deposits and payouts into both vault entry points. |
| `DonationVaultBoundary.t.sol` | One base unit, the entire supply, maximum uint256 rejection, split-versus-whole equivalence, unknown gift IDs, and contract-wallet donor/claimer attribution. |
| `LaunchTokenBoundary.t.sol` | Approval replacement, revocation, spender/owner isolation, delegated self-transfers, unlimited approval, maximum uint256 rejection, empty-wallet zero transfers, and zero-address validation at zero amount. |
| `DonationVaultWalletGas.t.sol` | The supplied `WalletGas` helper compares return data and events at the least successful gas limit and with gas to spare for both `donate` and `claim`. Cases include the first and subsequent gifts, fractions, one base unit, the full supply, finite/infinite approvals, final/nonfinal payouts, surplus, and a token with no return data. |
| `DonationVaultInvariant.t.sol` | Four persistent properties across 256 random sequences of 64 calls, followed by payout of every remaining open gift. |

New stateless fuzz properties run 1,000 cases each through inline Foundry settings.
The existing `DonationVaultTest.testFuzzDonateClaim` now maps every input to a
funded, positive donation instead of returning without assertions for most inputs.
The existing launch and real-token integration tests remain part of the combined suite.

## Invariant design

The five discovery perspectives in the supplied Pashov guide were applied locally.
These are required properties of the approved gifts and fixed-supply token:

| Perspective | Property and source basis | Where checked |
| --- | --- | --- |
| Conservation | `totalSupply == sum(all tracked balances) == 10^27`; actual vault balance equals unpaid gifts plus separately tracked direct-transfer surplus. Token allocation and transfers: `src/LaunchToken.sol:8`, `:22`, `:49`; gift liabilities: `src/DonationVault.sol:29`, `:63`, `:79`. | `invariantFixedSupplyAndAllBalancesAreConserved`, `invariantGiftsRemainImmutableAndPayOnlyOnce`. |
| State transitions | Gift IDs only advance on successful donations. Donor/amount never change. A gift can move from open to paid once, and failed actions change neither balances nor liabilities. Points persist after payout. Basis: vault `donate`, `claim`, and permanent-point documentation at `src/DonationVault.sol:12`. | Gift, allowance, and point invariants; atomic failure tests. |
| Round trips and rounding | Whole and fractional base units survive donation and payout exactly. Splitting a gift does not change aggregate points or payout. A donor/claimer/return-transfer cycle creates no tokens. There is no share conversion or yield calculation in this vault. | `roundTrip` handler, splitting fuzz property, one-unit and full-supply cases. |
| Adversarial value and liveness | Self/unknown/repeated claims cannot pay. Reentry cannot claim an additional gift or create points. Failed token calls roll back and release the lock. Every eligible open gift remains payable after mixed sequences. Basis: vault guards at `src/DonationVault.sol:49`, `:81`, and checked call at `:121`. | Invalid-action handlers, reentrancy tests, rollback tests, `afterInvariant`. |
| Protocol-specific | ERC-20 self-transfers conserve balance; finite allowances decrement, infinite allowances persist, replacing/revoking an approval is local to its owner/spender pair. Only donations credit donor points. Basis: `src/LaunchToken.sol:32`, `:39`, `:49`, and `src/DonationVault.sol:63`. | Token boundary tests and allowance/point invariants. |

`helpers/DonationSequenceHandler.sol` uses four distinct actors and an independent
record of successful action inputs for balances, allowances, gifts, gross donations,
payouts and surplus. It never refreshes that model from the contracts' post-call
state. Amounts include dust, whole-token boundaries, full available balances, and
bounded arbitrary values. Actors can donate, claim, transfer, approve/revoke, spend
allowances, send tokens directly, attempt invalid operations, and round-trip gifts.
Only those ten action selectors are targeted.

Unexpected success, rejection, return data or revert data sets a sticky failure
flag checked by an invariant. This makes failures observable even when the runner
is configured to ignore handler reverts. An explicit handler test reaches both
successful and rejected operations. `afterInvariant` then pays every outstanding
gift and rechecks all properties, including persistent donor points.

Gross points and direct-transfer surplus follow the approved, documented behavior:
points are permanent gross donation units, not redeemable balances, and direct
transfers create neither gifts nor points. No property incorrectly caps lifetime
points at token supply or treats surplus as an outstanding gift.

## Dependencies and limits

`vendor/forge-std` contains the unmodified dependency closure of upstream
`Test.sol` at v1.9.7, including its licenses and archive provenance. It is ordinary
source with relative imports, so no remapping, submodule, or installation is needed
on an offline verifier. `helpers/WalletGas.sol` is the supplied helper copied in
full, with only its import changed to the vendored path.

The adversarial token is a test fixture for the vault's checked-call boundary,
not a replacement for the real-token integration. The fee fixture taxes incoming
deposits and makes exact payouts; it does not establish support for arbitrary
rebasing, dishonest, or payout-taxing tokens. The missing-code tests temporarily
remove that fixture's code to exercise first-use and payout failure paths.

No fork block or deployed Sepolia contract addresses were provided for this
assignment. Live launch receipts, Uniswap v4 pool initialization/liquidity, router
and quoter integration, buys, and frontend/IPFS evidence remain checks for the
deployment and frontend stages; this suite makes no claims about that live state.
