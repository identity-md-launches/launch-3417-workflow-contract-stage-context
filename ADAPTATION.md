# Launch adaptation

This is the contracts/source contribution for the approved Sepolia `evm_project` release of `LaunchToken` and `DonationVault`. The existing constructors and token already meet the launch rules, so no executable contract behavior was changed. Both contracts are nonpayable at construction; `LaunchToken()` mints the fixed `10^27` base units to the factory, and `DonationVault(address token_)` binds `$token` without external calls or initialization. Neither contract grants an admin role, and the vault receives no launch allocation.

## Changes and reasons

| File | Change | Requirement or reproduced finding |
| --- | --- | --- |
| `src/DonationVault.sol` | NatSpec now explicitly describes gross, farmable points, address-only self-claim exclusion and permanently locked direct transfers. | Findings `abb45648…` and `17c3d40b…` call for disclosure while preserving approved public gifts and permanent points. |
| `test/DonationVaultIntegration.t.sol` | Six tests using the actual fixed-supply `LaunchToken`: the fractional flow, two atomic donation failures, two audit reproductions and fuzzed multi-donor accounting. | Approved real-token integration gate and all three audit findings. |
| `test/ProjectLaunch.t.sol` | Tests single-call factory deployment with CREATE2, whole-supply retention, empty vault state, runtime size and construction with a token address that has no code yet. | Factory-callable constructors, no initialization, no initial vault allocation and empty-chain constructor requirements. The helper factory is test-only. |
| `README.md` | Documents contract configuration, donation flow, public claims, point units, custody limitations, frontend disclosure copy and verification commands. | Approved behavior, audit disclosures and the contract-to-frontend handoff. |
| `docs/abi/LaunchToken.json`, `docs/abi/DonationVault.json` | Compiler-generated ABI arrays for both launch contracts. | Source-producing assignment's ABI export requirement. |
| `docs/abi/README.md` | Documents constructor arguments, units, functions, events, errors and ABI regeneration. | Usable ABI documentation for manifest and frontend integration. |
| `ADAPTATION.md` | Records each change, finding disposition and validation. | Adaptation acceptance criterion. |

The existing build configuration, dependencies, `src/LaunchToken.sol` and original tests are unchanged. No new dependencies, constructor settings or economic parameters were introduced. The manifest remains the separate manifest assignment's output. Deployment, policy/signed artifact linkage, source publication, live pool checks and site publication belong to the subsequent services and frontend work.

## Audit reproduction and disposition

All three findings reproduced against the original executable source. None was rejected as non-reproducible.

**`abb45648f8507d06d085e4dfeff213ee00cd189d2fa5fbb5d2fc80610c6b0dd5` — gross points can be farmed (low).** `testPointsCanBeFarmedThroughASecondWallet` repeats ten 100-token donations, second-wallet claims and return transfers using `LaunchToken`. The donor ends with the original 100 tokens, the vault is empty, and the donor retains 1,000 points. This behavior follows the approved public gifts, address-only exclusion and persistent points. The remedy is explicit disclosure in the README, frontend copy, ABI guide and NatSpec: points measure gross donations, can be farmed and must not be used for allocations or rewards. Identity checks, claim delays, chosen recipients or changing point crediting would alter the approved behavior and were not added. This limitation remains by design.

**`6ff3ef17115165ee3db8d0ceac9e855d44fe87eb4ee0de63757afa475f04e820` — missing real-token integration test (low).** The original 24-test suite contained only isolated `LaunchToken` tests and vault tests using `MockToken`. The new integration suite deploys both real contracts and funds wallets through `transfer`. `testApproveDonateAndClaimFractionalGift` checks exact approval of 1.5 tokens, allowance consumption, donation and claim events, a donor self-claim revert, a second-wallet full payout, permanent donor points, a third-wallet repeat-claim revert and zero final outstanding/balance. Two additional tests verify `TransferFailed` for insufficient balance and insufficient allowance, with unchanged allowance, balances, gifts and points after failure and a successful subsequent donation. The coverage gap is fixed.

**`17c3d40b4f65e23ee26e9a6735344c88b182adf7003179a75face25953677eaa` — direct transfers are locked (informational).** `testDirectTransferStaysLockedAfterLaterGiftIsClaimed` transfers 5 real tokens directly to the vault, observes no gifts, points or outstanding amount, and checks `UnknownGift` for IDs 0 and 1. A later 1.5-token donation and claim leave the original 5-token surplus locked; repeat claims cannot recover it. Source inspection confirms that only `donate` and `claim` change vault state and there is no recovery path. The README, frontend copy, ABI guide and NatSpec now warn users to approve and donate rather than transfer directly. A surplus-conversion or rescue function would change the approved behavior and was not added. This custody limitation remains by design.

## Validation

The original suite passed all 24 tests with the supplied fuzz seed. Before the documentation changes, all six new real-token integration tests also passed against the original source, confirming the reproductions above.

Final checks use the unchanged Foundry configuration and Solidity `0.8.26`:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x9e9dbb18f92a78de9adcdfdac3fb6e4441fb001bb12de4a98ff08c49f7ee2cb9 forge test
```

Results: `forge build` succeeded; `forge test` passed **32 tests across four suites**, with zero failures or skips. Each of the five fuzz tests ran 256 cases using the supplied seed. Both exported ABI arrays match their compiler artifact's `abi` field exactly. Constructor ABI checks confirmed no arguments for `LaunchToken` and one `address` for `DonationVault`, both nonpayable, with no linked libraries.

The compiled runtime sizes are 1,438 bytes for `LaunchToken` and 2,167 bytes for `DonationVault`, below the 24,576-byte limit. A local scan using the protected check's reachable-opcode rule found no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. Comparing the compiler's creation and runtime bytecode before and after the changes found them byte-for-byte identical for both contracts; the `foundry.toml` checksum is also unchanged.

Foundry's build linter emitted `reentrancy-no-eth` at the existing low-level token call and `reentrancy-events` at the two vault events. Both state-changing entry points hold the existing `nonReentrant` lock across those calls and events, and the bound `LaunchToken` has no callbacks. No contract change or lint suppression was made for these advisories. Slither and Mythril were not run. These local checks are not the independent source/manifest review or evidence of a live deployment.
