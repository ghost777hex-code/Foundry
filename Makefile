-include .env

.PHONY: all play install build test test-ci coverage snapshot fmt fmt-check clean anvil deploy-local deploy-sepolia

all: build test

install:
	forge install

build:
	forge build --sizes

test:
	forge test -vvv

test-ci:
	FOUNDRY_PROFILE=ci forge test -vvv

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
deploy-local:
	forge script script/Counter.s.sol:CounterScript --rpc-url localhost --broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Requires: cast wallet import deployer --interactive
deploy-sepolia:
	forge script script/Counter.s.sol:CounterScript --rpc-url sepolia --account deployer --broadcast --verify

play:
	forge script script/Playground.s.sol --tc Playground
