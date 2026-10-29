// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IWETH9} from "./IWETH9.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {CommonBase} from "forge-std/Base.sol";

/// @notice Deploys Uniswap v2/v3 from the official npm build artifacts (the exact mainnet bytecode),
/// so the pair/pool init code hashes hardcoded in the routers match. Usable from both Test and Script.
abstract contract UniswapDeployer is CommonBase {
    string internal constant V2_CORE = "node_modules/@uniswap/v2-core/build/";
    string internal constant V2_PERIPHERY = "node_modules/@uniswap/v2-periphery/build/";
    string internal constant V3_CORE = "node_modules/@uniswap/v3-core/artifacts/contracts/";
    string internal constant V3_PERIPHERY = "node_modules/@uniswap/v3-periphery/artifacts/contracts/";

    IWETH9 public weth;

    IUniswapV2Factory public v2Factory;
    IUniswapV2Router02 public v2Router;

    IUniswapV3Factory public v3Factory;
    ISwapRouter public v3Router;
    INonfungiblePositionManager public positionManager;
    IQuoterV2 public quoter;

    function deployUniswap(address feeToSetter) internal {
        weth = IWETH9(_deploy(string.concat(V2_PERIPHERY, "WETH9.json"), ""));

        v2Factory = IUniswapV2Factory(_deploy(string.concat(V2_CORE, "UniswapV2Factory.json"), abi.encode(feeToSetter)));
        v2Router = IUniswapV2Router02(
            _deploy(string.concat(V2_PERIPHERY, "UniswapV2Router02.json"), abi.encode(v2Factory, weth))
        );

        v3Factory = IUniswapV3Factory(_deploy(string.concat(V3_CORE, "UniswapV3Factory.sol/UniswapV3Factory.json"), ""));
        v3Router = ISwapRouter(
            _deploy(string.concat(V3_PERIPHERY, "SwapRouter.sol/SwapRouter.json"), abi.encode(v3Factory, weth))
        );
        // Token descriptor is address(0): tokenURI() reverts, everything else works.
        positionManager = INonfungiblePositionManager(
            _deploy(
                string.concat(V3_PERIPHERY, "NonfungiblePositionManager.sol/NonfungiblePositionManager.json"),
                abi.encode(v3Factory, weth, address(0))
            )
        );
        quoter = IQuoterV2(
            _deploy(string.concat(V3_PERIPHERY, "lens/QuoterV2.sol/QuoterV2.json"), abi.encode(v3Factory, weth))
        );

        vm.label(address(weth), "WETH9");
        vm.label(address(v2Factory), "UniswapV2Factory");
        vm.label(address(v2Router), "UniswapV2Router02");
        vm.label(address(v3Factory), "UniswapV3Factory");
        vm.label(address(v3Router), "SwapRouter");
        vm.label(address(positionManager), "NonfungiblePositionManager");
        vm.label(address(quoter), "QuoterV2");
    }

    function _deploy(string memory artifact, bytes memory args) private returns (address addr) {
        // vm.getCode() can't parse the v2 (Waffle) artifacts, so read the `bytecode` field directly.
        bytes memory code =
            abi.encodePacked(vm.parseBytes(vm.parseJsonString(vm.readFile(artifact), ".bytecode")), args);
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), string.concat("deploy failed: ", artifact));
    }
}
