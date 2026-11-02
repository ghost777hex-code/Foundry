// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

/// @notice Ethereum mainnet addresses used by the fork tests.
library Mainnet {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address internal constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address internal constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant V3_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address internal constant V3_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
}

/// @notice Base for tests that run against a fork of Ethereum mainnet.
///
/// The RPC URL comes from the `mainnet` alias in foundry.toml [rpc_endpoints].
/// Forks the latest block, so the tests check against on-chain math rather than hardcoded numbers.
/// To pin a block (reproducible, cached in ~/.foundry/cache/rpc), pass it as a second argument;
/// that needs an archive node (e.g. Alchemy/Infura) in foundry.toml.
abstract contract MainnetForkTest is Test {
    uint256 internal forkId;

    function setUp() public virtual {
        // createSelectFork = createFork + selectFork: from here on every call reads mainnet state.
        forkId = vm.createSelectFork("mainnet");
    }
}
