# Contract ABI reference

[LaunchToken.json](LaunchToken.json) and [DonationVault.json](DonationVault.json) are Solidity ABI arrays, including constructors, functions, events and custom errors. They contain no deployment addresses. Use addresses from the deployment handoff for Sepolia, chain ID `11155111`.

## LaunchToken

The nonpayable constructor takes no arguments and mints exactly `10^27` base units to its caller (the factory). All token amounts and allowances use 18 decimals.

| Function | Result or effect |
| --- | --- |
| `name()` / `symbol()` / `decimals()` | `"test"` / `"testAdam"` / `18`. |
| `totalSupply()` | Constant `1000000000000000000000000000`. |
| `balanceOf(address account)` | Account balance in base units. |
| `allowance(address owner, address spender)` | Remaining approved amount. |
| `approve(address spender, uint256 value)` | Sets the caller's allowance; returns `true`, emits `Approval`. Use the entered donation amount for the vault approval. |
| `transfer(address to, uint256 value)` | Moves the caller's tokens; returns `true`, emits `Transfer`. |
| `transferFrom(address from, address to, uint256 value)` | Spends the caller's allowance from `from`; returns `true`, emits `Transfer`. Maximum `uint256` allowance is not decreased. |

`Transfer(address indexed from, address indexed to, uint256 value)` also records the constructor's mint from the zero address. `Approval(address indexed owner, address indexed spender, uint256 value)` records explicit approvals. Allowance spending does not emit another `Approval`; reread `allowance` after a receipt.

Token custom errors are `ERC20InvalidSender(address)`, `ERC20InvalidReceiver(address)`, `ERC20InvalidSpender(address)`, `ERC20InsufficientBalance(address,uint256,uint256)` and `ERC20InsufficientAllowance(address,uint256,uint256)`. The last two include the current and required amounts. Failed operations revert all effects.

## DonationVault

The nonpayable constructor takes one `address token_`, supplied as `$token` by the manifest. A zero argument reverts `ZeroAddress()`. The token address is immutable; construction performs no external call and requires no code at that address yet. All functions below that change state are also nonpayable.

| Function | Result or effect |
| --- | --- |
| `token()` | The bound token's address. |
| `donate(uint256 amount)` | Pulls tokens from the caller using its allowance; returns a new `uint256 giftId`. Records the amount actually received and adds that amount to the donor's points and `totalOutstanding`. |
| `claim(uint256 giftId)` | Pays the recorded gift to the caller, if unclaimed and the caller is not the donor address. Returns the `uint256 amount` paid and decreases `totalOutstanding`; donor points persist. |
| `giftCount()` | Number of gifts ever created. IDs are `1..giftCount()`, including paid gifts. |
| `getGift(uint256 giftId)` | `(address donor, uint256 amount, bool claimed)`. |
| `giftDonor(uint256 giftId)` / `giftAmount(uint256 giftId)` / `isClaimed(uint256 giftId)` | Individual fields of the same gift record. |
| `points(address account)` | Permanent, nontransferable gross donation points, scaled by `10^18`. |
| `totalOutstanding()` | Sum of all recorded, unclaimed gift amounts, in token base units. |

Unknown gift IDs return `(address(0), 0, false)` from the getters, but cannot be claimed. Paid gift records retain their donor and amount with `claimed = true`. Successful transaction receipts contain the emitted events; a normal wallet transaction receipt does not expose the Solidity return value.

| Event | Meaning |
| --- | --- |
| `Donated(uint256 indexed giftId, address indexed donor, uint256 amount)` | A new public gift was recorded and donor points credited. |
| `Claimed(uint256 indexed giftId, address indexed claimer, uint256 amount)` | The gift was paid in full to this claimant. |

| Vault error | Meaning and client response |
| --- | --- |
| `ZeroAddress()` | Invalid constructor token argument. |
| `ZeroAmount()` | Donation amount must be greater than zero. |
| `NothingReceived()` | The transfer produced no positive received amount; no gift or points are recorded. |
| `UnknownGift(uint256 giftId)` | No gift exists at this ID. Refresh the gift list. |
| `AlreadyClaimed(uint256 giftId)` | A previous claim won. Refresh the gift and balances. |
| `SelfClaim(uint256 giftId)` | The caller is the donor address. Other addresses are eligible, including those controlled by the donor. |
| `TransferFailed()` | A token transfer failed. For donations, check token balance and allowance. Token transfer reverts (including insufficient balance or allowance) are wrapped in this error. |
| `Reentrancy()` | A nested donation or claim was rejected. |

The supported launch binds the vault to `LaunchToken`. Point amounts and exact payouts above describe that token. A direct token transfer to the vault creates no gift or points and is permanently locked. Points can be farmed through a second wallet and must not determine allocations or rewards. Show the [README disclosures](../../README.md#gifts-and-points) in the frontend.

## Regeneration

From the repository root, using the existing compiler configuration:

```sh
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/DonationVault.sol:DonationVault abi --json > docs/abi/DonationVault.json
```

The JSON arrays should match the respective `abi` fields in the compiler's `out/<Contract>.sol/<Contract>.json` artifacts.
