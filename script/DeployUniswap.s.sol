// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {UniswapDeployer} from "../test/utils/UniswapDeployer.sol";
import {Script, console} from "forge-std/Script.sol";

/// @notice Deploys WETH9 + Uniswap v2/v3 to a local chain.
/// forge script script/DeployUniswap.s.sol --rpc-url localhost --broadcast --private-key <anvil key>
contract DeployUniswap is Script, UniswapDeployer {
    function run() public {
        vm.startBroadcast();
        deployUniswap(msg.sender);
        vm.stopBroadcast();

        console.log("WETH9                      ", address(weth));
        console.log("UniswapV2Factory           ", address(v2Factory));
        console.log("UniswapV2Router02          ", address(v2Router));
        console.log("UniswapV3Factory           ", address(v3Factory));
        console.log("SwapRouter                 ", address(v3Router));
        console.log("NonfungiblePositionManager ", address(positionManager));
        console.log("QuoterV2                   ", address(quoter));
    }
}
