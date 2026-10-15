# Solidity (Foundry)

Smart-contract workspace built on [Foundry](https://book.getfoundry.sh/): `forge` (build/test), `cast` (chain CLI), `anvil` (local node), `chisel` (REPL).

## Setup

```sh
curl -L https://foundry.paradigm.xyz | bash && foundryup   # install toolchain
git clone --recursive <repo> && cd <repo>                  # or: forge install
cp .env.example .env                                        # fill RPC URLs / Etherscan key
```

## Layout

| Path | Purpose |
|---|---|
| `src/` | Contracts |
| `test/` | Tests (`*.t.sol`) — unit, fuzz, invariant |
| `script/` | Deploy scripts (`*.s.sol`) |
| `lib/` | Dependencies (git submodules, e.g. `forge-std`) |
| `foundry.toml` | Compiler, fuzz, fmt, RPC and Etherscan config |

## Commands

| `make` target | Does |
|---|---|
| `build` | Compile and print contract sizes |
| `test` | Run tests (256 fuzz runs) |
| `test-ci` | Run tests with the `ci` profile (10k fuzz runs) |
| `coverage` / `snapshot` | Coverage summary / gas snapshot |
| `fmt` / `fmt-check` | Format / verify formatting |
| `anvil` | Start a local node on `127.0.0.1:8545` |
| `deploy-local` | Deploy `Counter` to a running anvil |
| `deploy-sepolia` | Deploy + verify on Sepolia using the `deployer` keystore |

Run a single test: `forge test --match-test test_Increment -vvvv`.

## Deploying to a live network

Use an encrypted keystore instead of putting a private key in `.env`:

```sh
cast wallet import deployer --interactive
make deploy-sepolia
```

## Adding dependencies

```sh
forge install OpenZeppelin/openzeppelin-contracts
echo "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/" >> remappings.txt
```
