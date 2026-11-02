// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Mainnet, MainnetForkTest} from "./MainnetFork.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/// @notice Swaps and adds/removes liquidity through the real mainnet v2 Router02 on the live WETH/DAI pair.
/// Pool reserves depend on the fork block, so results are checked against the router's own math
/// (getAmountsOut, quote) instead of hardcoded numbers.
contract UniswapV2ForkTest is MainnetForkTest {
    IUniswapV2Factory internal constant FACTORY = IUniswapV2Factory(Mainnet.V2_FACTORY);
    IUniswapV2Router02 internal constant ROUTER = IUniswapV2Router02(Mainnet.V2_ROUTER);
    IERC20 internal constant WETH = IERC20(Mainnet.WETH);
    IERC20 internal constant DAI = IERC20(Mainnet.DAI);

    IUniswapV2Pair public pair;
    address public alice = makeAddr("alice");

    function setUp() public override {
        super.setUp();
        pair = IUniswapV2Pair(FACTORY.getPair(Mainnet.WETH, Mainnet.DAI));

        vm.label(address(FACTORY), "UniswapV2Factory");
        vm.label(address(ROUTER), "UniswapV2Router02");
        vm.label(address(pair), "WETH/DAI");
        vm.label(Mainnet.WETH, "WETH");
        vm.label(Mainnet.DAI, "DAI");
    }

    function _path(address tokenIn, address tokenOut) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
    }

    function test_Fork_SwapWethForDai() public {
        uint256 amountIn = 10 ether;
        deal(Mainnet.WETH, alice, amountIn);
        address[] memory path = _path(Mainnet.WETH, Mainnet.DAI);
        uint256 expectedOut = ROUTER.getAmountsOut(amountIn, path)[1];
        // getAmountsOut == getAmountOut(amountIn, reserveIn, reserveOut). DAI (0x6B..) < WETH (0xC0..): token0 = DAI.
        (uint112 reserveDaiBefore, uint112 reserveWethBefore,) = pair.getReserves();
        assertEq(expectedOut, ROUTER.getAmountOut(amountIn, reserveWethBefore, reserveDaiBefore));
        uint256 pairWethBefore = WETH.balanceOf(address(pair));
        uint256 pairDaiBefore = DAI.balanceOf(address(pair));

        vm.startPrank(alice);
        WETH.approve(address(ROUTER), amountIn);
        uint256[] memory amounts = ROUTER.swapExactTokensForTokens(amountIn, expectedOut, path, alice, block.timestamp);
        vm.stopPrank();
        uint256 amountOut = amounts[1];
        assertEq(amounts[0], amountIn);
        assertEq(amountOut, expectedOut);
        assertEq(WETH.balanceOf(alice), 0);
        assertEq(DAI.balanceOf(alice), amountOut);
        assertEq(DAI.balanceOf(address(ROUTER)), 0);

        // The pair received exactly amountIn WETH and paid out exactly amountOut DAI.
        assertEq(WETH.balanceOf(address(pair)), pairWethBefore + amountIn);
        assertEq(DAI.balanceOf(address(pair)), pairDaiBefore - amountOut);
        // swap() ends with _update(), so the reserves now match the real balances.
        (uint112 reserveDai, uint112 reserveWeth,) = pair.getReserves();
        assertEq(reserveWeth, WETH.balanceOf(address(pair)));
        assertEq(reserveDai, DAI.balanceOf(address(pair)));
        assertEq(pair.token0(), Mainnet.DAI);
        emit log_named_decimal_uint("DAI for 10 WETH", amountOut, 18);
    }

    function test_Fork_SwapDaiForExactWeth() public {
        uint256 wethWanted = 1 ether;
        address[] memory path = _path(Mainnet.DAI, Mainnet.WETH);
        uint256 daiNeeded = ROUTER.getAmountsIn(wethWanted, path)[0];
        deal(Mainnet.DAI, alice, daiNeeded);

        vm.startPrank(alice);
        DAI.approve(address(ROUTER), daiNeeded);
        uint256[] memory amounts = ROUTER.swapTokensForExactTokens(wethWanted, daiNeeded, path, alice, block.timestamp);
        vm.stopPrank();

        assertEq(amounts[0], daiNeeded);
        assertEq(WETH.balanceOf(alice), wethWanted);
        assertEq(DAI.balanceOf(alice), 0);
    }

    function test_Fork_AddLiquidityAndRemoveLiquidity() public {
        uint256 wethDesired = 10 ether;
        uint256 daiDesired = 1_000_000 ether;
        deal(Mainnet.WETH, alice, wethDesired);
        deal(Mainnet.DAI, alice, daiDesired);
        // Router uses all WETH and the DAI amount that keeps the pool ratio: quote(amountA, reserveA, reserveB).
        (uint112 reserveDai, uint112 reserveWeth,) = pair.getReserves();
        uint256 daiOptimal = ROUTER.quote(wethDesired, reserveWeth, reserveDai);

        vm.startPrank(alice);
        WETH.approve(address(ROUTER), wethDesired);
        DAI.approve(address(ROUTER), daiDesired);
        (uint256 wethIn, uint256 daiIn, uint256 liquidity) =
            ROUTER.addLiquidity(Mainnet.WETH, Mainnet.DAI, wethDesired, daiDesired, 0, 0, alice, block.timestamp);
        assertEq(wethIn, wethDesired);
        assertEq(daiIn, daiOptimal);
        assertLt(daiIn, daiDesired);
        assertEq(pair.balanceOf(alice), liquidity);

        pair.approve(address(ROUTER), liquidity);
        (uint256 wethOut, uint256 daiOut) =
            ROUTER.removeLiquidity(Mainnet.WETH, Mainnet.DAI, liquidity, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        assertEq(pair.balanceOf(alice), 0);
        assertLe(wethOut, wethIn);
        assertLe(daiOut, daiIn);
        assertApproxEqRel(wethOut, wethIn, 1e12); // 0.0001%
        assertApproxEqRel(daiOut, daiIn, 1e12);
    }
}
