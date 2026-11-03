-include .env

.PHONY: all install build test test-ci test-fork challenge-1 challenge-2 challenge-3 coverage snapshot fmt fmt-check clean anvil deploy-uniswap-local

all: build test

install:
	forge install
	npm ci

build:
	forge build --sizes

test:
	forge test -vvv

test-ci:
	FOUNDRY_PROFILE=ci forge test -vvv

# Mainnet fork tests; RPC URL is the `mainnet` alias in foundry.toml
test-fork:
	forge test --match-path "test/fork/*" -vvv

# Uniswap v2 code challenges: src/challenges/ (problems), test/fork/challenges/ (tests)
challenge-1:
	forge test --match-path test/fork/challenges/Challenge1AmountMath.t.sol -vv

challenge-2:
	forge test --match-path test/fork/challenges/Challenge2MultiHop.t.sol -vv

challenge-3:
	forge test --match-path test/fork/challenges/Challenge3FlashSwap.t.sol -vv

coverage:
	forge coverage --report summary

snapshot:
	forge snapshot

fmt:
	forge fmt

fmt-check:
	forge fmt --check

clean:
	forge clean

anvil:
	anvil

# Uses anvil's first default account (local only)
deploy-uniswap-local:
	forge script script/DeployUniswap.s.sol:DeployUniswap --rpc-url localhost --broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
