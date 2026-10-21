# Mutually Assured Destruction (MAD)

MAD is an immutable, fixed-supply ERC-20. Its constructor assigns the entire supply to the immediate deployer and emits the standard mint `Transfer` event.

| Parameter | Value |
| --- | --- |
| Solidity deployment artifact | `src/MADToken.sol:MADToken` |
| Token name | `Mutually Assured Destruction` |
| Symbol | `MAD` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Named supply constant | `INITIAL_SUPPLY` |
| Constructor arguments | None; ABI argument list `[]` |
| Constructor transaction value | `0` |
| Initial supply recipient | `msg.sender`, the contract or account executing CREATE/CREATE2 |
| Administrator / owner | None |

## Behavior and assumptions

The brief specifies the token's identity and supply. “Mutually Assured Destruction” is treated as branding; no destruction, burn, tax, reflection, staking, governance, or other economic mechanism is implied. This deliverable contains only the requested token and its ERC-20 interface.

All valid transfers deliver exactly the requested amount. There are no transfer fees, exemptions, limits, pauses, blacklists, hooks, external calls, or restrictions tied to the launch addresses. The total supply cannot change after construction. There is no mint, burn, ownership, upgrade, initialization, or recovery entry point.

`transfer`, `approve`, and `transferFrom` return `true` on success and revert on failure. Amounts are always expressed in the smallest units. Zero-value transfers and self transfers are supported and emit `Transfer`; a self transfer still requires sufficient balance. Transfers from or to the zero address revert, including zero-value transfers. Approving the zero address also reverts. Custom errors describe insufficient balances, insufficient allowances, and invalid addresses.

`approve` replaces the caller's allowance and emits `Approval`. A zero allowance revokes permission. `transferFrom` decreases a finite allowance, while `type(uint256).max` grants unlimited permission and remains unchanged when spent. Even the balance owner needs an allowance if calling `transferFrom`; owners can use `transfer` directly. Spending an allowance emits `Transfer`, without an additional `Approval` event. Indexers should query `allowance` for its current value. Any failed transfer rolls back both balances and allowance changes.

ERC-20 transfers do not invoke the recipient. Tokens sent to this token contract, or another address unable to transfer them, cannot be recovered by an administrator. Ordinary native-currency payments and unknown function calls revert; forcibly received native currency would also have no recovery mechanism.

## Build and test

The project is self-contained. All required source and test support is in the repository; there are no package downloads, submodules, linked libraries, or Solidity dependencies to install. Foundry and its Solidity 0.8.26 compiler are the only build tools required. Tests use local Foundry cheatcodes and do not read environment variables, fork a network, or access the filesystem.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x9fbfc1c0355f317f1d8824a4c2b4dfcd7db17e7002009968da9654daa67a551e forge test
forge fmt --check
```

`foundry.toml` pins Solidity `0.8.26`, the Cancun EVM target, optimization with 200 runs, and `bytecode_hash = "none"`. It enables no FFI or filesystem permissions. Unit fuzz tests run 256 cases each. The stateful invariant runs 128 sequences of 64 actions, with unexpected handler reverts treated as failures. The fuzz seed is supplied to the test runner, not read or changed by any test.

The tests cover:

- Exact metadata, initial balances, the constructor mint event, and CREATE2 deployment through a factory.
- Full-supply transfers, zero amounts, self transfers, and recipients that reject callbacks.
- Approvals, overwrite/revocation, independent owners and spenders, finite and unlimited allowances.
- Invalid addresses, overspending, unauthorized spending, and atomic rollback after failed transfers.
- Rejection of mint, burn, freeze, seizure, ownership, and upgrade calls from both the deployer and a stranger.
- Exact token transfers for the launch distribution, distributor claims, and buy/sell token legs.
- Fuzzed amounts and recipients, plus a stateful independent accounting model checking every tracked balance and allowance and conservation of the whole supply.

The local launch-flow test checks token movements only. It does not implement or simulate AMM pricing, initialize a real Uniswap pool, or execute the supplied external launch harness. The pinned protected checks depend on launch-system contracts and configuration outside this repository; those remain the independent verifier's integration checks.

## Deployment and launch responsibilities

Deploy the `MADToken` creation bytecode built with the committed configuration, without constructor arguments or attached native currency. No initializer or subsequent configuration transaction is required. Deploying through a factory assigns all tokens to that factory; calling a helper that deploys the token assigns them to the helper. The launch must use the intended factory as the immediate deployer, and that factory must be able to distribute the tokens.

The assignment's Ethereum launch (chain ID 1) specifies the following external allocation. The token constructor performs none of these distributions: it mints the entire supply to the factory once.

| Factory allocation | Share of original supply | Whole MAD |
| --- | --- | --- |
| Launch MerkleDistributor | 10% | 100,000,000 |
| Pool | 60% | 600,000,000 |
| Requester's remainder | 30% | 300,000,000 |

The requester's remainder destination supplied by the assignment is `0x3ed212257958724579f13b3dba74a07ac6007903`. The launch's paired currency is FWA at `0xa0df17b5ac76ababa36e1450e2cbcd18a620c845`, with 18 decimals. These are launch configuration values, not token constructor parameters, and their live on-chain state was not queried by this project.

The launch policy supplies the pool fee `12500` (1.25%), tick spacing `60`, provenance price `79228162514264337593543950336`, and economics `poolBps = 6000` and `initialMarketCapWei = 500000000000000000000000`. The launch system derives the actual opening price. These values belong to the separate manifest and launch system. The builder does not provide `launch.json`, a pool, a distributor, or a deployment broadcaster.

The network deployer is responsible for generating and validating the manifest, running the protected integration checks, deploying the reviewed bytecode, distributing the supply through the factory, and publishing the deployed address and verified source. No transaction is broadcast by this repository.

## After launch

There are no owner-settable parameters, privileged operators, keepers, or maintenance transactions. The deployer should confirm the exact metadata, `10^27` total supply, initial factory mint event, and subsequent allocation transfers on-chain. The factory's custody and distribution are part of the launch system's trust assumptions, not token administration.

Holders manage their own balances and approvals. An approved spender can spend up to its allowance; unlimited approvals permit all current and future balances. When replacing an existing nonzero approval, holders should revoke it and wait for confirmation before granting the new amount, accounting for any spending before revocation. Applications should request only the allowance they need.

The implementation and tests received a local review against the supplied security reference. The review found no external-call/reentrancy surface, mutable supply path, privileged balance control, proxy, or linked-library dependency. All arithmetic uses Solidity's checked operations. This is a manual implementation review with Foundry unit, fuzz, and invariant testing; Slither and Mythril were not run, and it is not an independent security audit. The launch's independent adversarial review and integration checks remain release responsibilities.
