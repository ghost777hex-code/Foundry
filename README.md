# Solidity (Foundry) + Uniswap v2/v3

Smart-contract workspace built on [Foundry](https://book.getfoundry.sh/): `forge` (build/test), `cast` (chain CLI), `anvil` (local node), `chisel` (REPL). Uniswap v2 and v3 can be deployed locally for tests.

## Setup

```sh
curl -L https://foundry.paradigm.xyz | bash && foundryup   # install toolchain
git clone --recursive <repo> && cd <repo>
make install                                                # forge install + npm ci
```

## Layout

| Path | Purpose |
|---|---|
| `src/` | Contracts |
| `test/` | Tests (`*.t.sol`) — unit, fuzz, invariant |
| `test/utils/UniswapDeployer.sol` | `deployUniswap(owner)`: deploys WETH9 + Uniswap v2/v3 (usable from tests and scripts) |
| `script/` | Deploy scripts (`*.s.sol`) |
| `lib/` | Dependencies (git submodules: `forge-std`, OpenZeppelin 4.9.6, Uniswap `v3-core`/`v3-periphery` `0.8` branches) |
| `node_modules/@uniswap/` | Official Uniswap npm packages (mainnet bytecode, v2 interfaces) |
| `test/fork/` | Mainnet fork tests against the live Uniswap v2/v3 contracts |
| `foundry.toml` | Compiler, fuzz, fmt and RPC config |

## Commands

| `make` target | Does |
|---|---|
| `install` | `forge install` + `npm ci` |
| `build` | Compile and print contract sizes |
| `test` | Run tests (256 fuzz runs) |
| `test-ci` | Run tests with the `ci` profile (10k fuzz runs) |
| `test-fork` | Run only the mainnet fork tests (needs network) |
| `coverage` / `snapshot` | Coverage summary / gas snapshot |
| `fmt` / `fmt-check` | Format / verify formatting |
| `anvil` | Start a local node on `127.0.0.1:8545` |
| `deploy-uniswap-local` | Deploy WETH9 + Uniswap v2/v3 to a running anvil |

Run a single test: `forge test --match-test test_V3_MintPositionAndSwap -vvvv`.

## Uniswap

The deployed contracts come from the official npm build artifacts, so the pair/pool init code hashes match mainnet and the routers work unmodified. Only the 0.8 interfaces and libraries are compiled.

```solidity
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
```

- Look up v3 pools with `factory.getPool(...)`. `PoolAddress.computeAddress` in `lib/v3-periphery` uses a different init code hash and returns the wrong address.
- Deployed v3 contracts are the 0.7.6 originals: they revert with short strings (`"SPL"`, `"TLM"`), not the custom errors in the `lib/` sources.
- `NonfungiblePositionManager.tokenURI()` reverts (no token descriptor deployed).
- Use `test/utils/IWETH9.sol`; the one in `lib/v3-periphery` pins `pragma solidity =0.8.15`.

## Deploying to a live network

Use an encrypted keystore instead of putting a private key in `.env`:

```sh
cast wallet import deployer --interactive
forge script script/<Script>.s.sol --rpc-url <rpc-url> --account deployer --broadcast
```
