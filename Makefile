-include .env

.PHONY: all install build test test-ci test-fork coverage snapshot fmt fmt-check clean anvil deploy-uniswap-local

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
