# test staking contracts

Contracts for the approved Ethereum Sepolia release (chain ID `11155111`). The application creates public gifts of testAdam and records permanent, proportional donor points.

## Contracts and launch

| Contract | Constructor | Launch behavior |
| --- | --- | --- |
| `LaunchToken` | `constructor()` | Mints the entire fixed supply to its deployer, the launch factory. |
| `DonationVault` | `constructor(address token_)` | Takes `$token`, the deployed `LaunchToken` address, as its sole argument. |

`LaunchToken` has the name **test**, symbol **testAdam**, 18 decimals and exactly **1,000,000,000 tokens** (`1000000000000000000000000000` base units). These are constants. There is no minting after construction, transfer fee, owner, pause, blocklist or upgrade mechanism.

Both constructors are nonpayable and need no initialization call. The vault stores a nonzero immutable token address without calling it during construction. A donation requires the token to be live. Neither contract has an owner or admin argument. The vault has no initial token allocation; it holds gifts deposited after launch.

The launch service distributes the factory's supply: 10% through its MerkleDistributor, 80% for launch liquidity and the remaining 10% to the paying wallet (or the policy treasury when applicable). The native Sepolia ETH/testAdam pool uses the launch policy's **1.25% fee** (`12500`) and tick spacing `60`. These contracts do not implement pool fees or pool initialization.

This contribution supplies source, offline tests and ABI documentation. The manifest assignment supplies `launch.json`; services publish, attest, admit and deploy the accepted source, then hand the live addresses, receipts and exact pool key to the frontend. Pool liquidity checks, buy simulation evidence and IPFS publication are later release work, not results claimed by this repository.

## Gifts and points

1. Parse the entered testAdam amount with 18 decimals. For example, 1.5 testAdam is `1500000000000000000` base units.
2. From the donor wallet, call `LaunchToken.approve(vaultAddress, amount)` for that exact amount and wait for its successful receipt.
3. From the same wallet, call `DonationVault.donate(amount)`. Only this function creates a gift and credits points. Read its gift ID from the receipt's `Donated` event; IDs start at 1.
4. The first wallet other than the donor address whose `claim(giftId)` succeeds receives the full recorded amount. Each gift pays once. Gifts are public, have no chosen recipient or expiry, and cannot be cancelled or refunded by the donor.

Each whole token received through `donate` earns one nontransferable point; fractions count without rounding to whole tokens. `points(account)` uses 18 decimals, so a 1.5-token donation earns 1.5 points. Points persist after payout. Claiming or transferring tokens does not earn points.

**Points count gross donations, not net tokens given away.** A donor can claim their own gift from a second wallet they control, return the tokens, and repeat while keeping all points. The contract excludes only the donor's address, not other wallets belonging to that person. Points can therefore be farmed for transaction costs and **must not be used for allocations or rewards**, or presented as proof of charitable giving or unique donors.

**Do not send tokens directly to the vault.** A plain ERC-20 transfer creates no gift and earns no points. Those tokens are permanently locked: the vault has no recovery or withdrawal function. Later donations and claims do not release them. Use approval followed by `donate`.

The vault's `totalOutstanding()` is the sum of unclaimed gift amounts. Its token balance equals that sum when all deposits use `donate`; direct transfers produce a surplus that is not claimable. The vault has no administrator who can redirect a gift or rescue that surplus. Any eligible wallet, including a bot or another wallet controlled by the donor, can win a public claim race.

## Frontend handoff

Use [the ABI reference](docs/abi/README.md) and the generated [LaunchToken ABI](docs/abi/LaunchToken.json) and [DonationVault ABI](docs/abi/DonationVault.json). Load contract addresses and chain information from the service deployment handoff.

For the wallet panel, read `balanceOf(account)` and `points(account)`. For gift browsing, read `giftCount()` and `getGift(id)` for IDs from 1 through that count, including amount and claim status. Show `totalOutstanding()` separately from the token balance. Refresh balances, points, allowances and gifts after successful transaction receipts; if another wallet wins a claim, handle `AlreadyClaimed` and refresh the gift instead of reporting a payout.

The site named **test staking** should show these disclosures alongside the donation form and points display:

> Points count gross donations and stay after payout. A donor can farm them by reclaiming gifts with a second wallet. Points are not proof of net giving and must not be used for allocations or rewards.

> Use Approve, then Donate. Sending testAdam directly to the vault permanently locks it, creates no gift and earns no points. Gifts made with Donate are public: the first wallet other than the donor address to claim receives the full gift.

Despite the site name, the vault provides public gifts, not staking yield or redeemable rewards. The frontend's quoted ETH buys and pool statistics must use the exact pool key and live protocol addresses from the deployment handoff.

## Local checks

The existing Foundry configuration pins Solidity `0.8.26`, Cancun, optimizer runs `200`, and disabled bytecode metadata. No new dependencies are required.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x9e9dbb18f92a78de9adcdfdac3fb6e4441fb001bb12de4a98ff08c49f7ee2cb9 forge test
```

`test/DonationVaultIntegration.t.sol` uses the real fixed-supply token for fractional approval/donation/claim, failed donations, claim races, persistent points, both audit behavior reproductions and fuzzed accounting. `test/ProjectLaunch.t.sol` checks factory deployment and construction before the token has code. The original token and mock-token vault tests remain in place. See [ADAPTATION.md](ADAPTATION.md) for audit dispositions and validation results.
