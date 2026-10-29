// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockERC20} from "./utils/MockERC20.sol";
import {UniswapDeployer} from "./utils/UniswapDeployer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Tests the official Uniswap v2 Router02 against the real v2 factory/pair.
contract UniswapV2RouterTest is Test, UniswapDeployer {
    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public alice = makeAddr("alice");

    function setUp() public {
        deployUniswap(address(this));
        vm.label(address(v2Factory), "UniswapV2Factory");
        vm.label(address(v2Router), "UniswapV2Router02");

        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000 ether);
        tokenA.approve(address(v2Router), type(uint256).max);
        tokenB.approve(address(v2Router), type(uint256).max);
    }

    function _pair() internal view returns (IUniswapV2Pair) {
        return IUniswapV2Pair(v2Factory.getPair(address(tokenA), address(tokenB)));
    }

    function _reserves() internal view returns (uint256 reserve0, uint256 reserve1) {
        (uint112 r0, uint112 r1,) = _pair().getReserves();
        (reserve0, reserve1) = address(tokenA) < address(tokenB) ? (r0, r1) : (r1, r0);
    }

    function _add(uint256 amountA, uint256 amountB) internal returns (uint256 a, uint256 b, uint256 liquidity) {
        return
            v2Router.addLiquidity(
                address(tokenA), address(tokenB), amountA, amountB, 0, 0, address(this), block.timestamp
            );
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, address to) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        return v2Router.swapExactTokensForTokens(amountIn, 0, path, to, block.timestamp)[1];
    }

    function _remove(address tokenA, address tokenB, uint256 liquidity, address to)
        internal
        returns (uint256 a, uint256 b)
    {
        (a, b) = v2Router.removeLiquidity(address(tokenA), address(tokenB), liquidity, 0, 0, to, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // addLiquidity
    // ---------------------------------------------------------------------

    function test_AddLiquidity() public {
        uint256 amountA = 100 ether;
        uint256 amountB = 400 ether;

        (uint256 a, uint256 b, uint256 liquidity) = _add(amountA, amountB);
        IUniswapV2Pair pair = _pair();

        assertTrue(address(pair) != address(0));
        assertEq(a, amountA);
        assertEq(b, amountB);
        assertEq(liquidity, Math.sqrt(amountA * amountB) - MINIMUM_LIQUIDITY);
        assertEq(pair.balanceOf(address(this)), liquidity);
        assertEq(pair.balanceOf(address(0)), MINIMUM_LIQUIDITY);
        assertEq(pair.totalSupply(), Math.sqrt(amountA * amountB));
        (uint256 reserve0, uint256 reserve1) = _reserves();
        assertEq(reserve0, amountA);
        assertEq(reserve1, amountB);
        assertEq(tokenA.balanceOf(address(this)), 1_000_000 ether - a);
        assertEq(tokenA.balanceOf(address(pair)), amountA);
        assertEq(tokenB.balanceOf(address(this)), 1_000_000 ether - b);
        assertEq(tokenB.balanceOf(address(pair)), amountB);
    }

    function test_AddLiquidity_MintsToRecepient() public {
        (,, uint256 liquidity) =
            v2Router.addLiquidity(address(tokenA), address(tokenB), 100 ether, 100 ether, 0, 0, alice, block.timestamp);
        assertEq(_pair().balanceOf(alice), liquidity);
    }

    function test_AddLiquidity_TokenALimited() public {
        _add(100 ether, 200 ether);
        (uint256 a, uint256 b,) = _add(10 ether, 40 ether);
        assertEq(a, 10 ether);
        assertEq(b, 20 ether);
    }

    function test_AddLiquidity_TokenBLimited() public {
        _add(1000 ether, 2000 ether);
        (uint256 a, uint256 b,) = _add(100 ether, 100 ether);
        assertEq(a, 50 ether);
        assertEq(b, 100 ether);
    }

    function test_AddLiquidity_RevertsBelowMin() public {
        _add(1000 ether, 1000 ether);
        // 100 A only needs 100 B; demanding at least 101 B must fail.
        vm.expectRevert();
        v2Router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 500 ether, 0, 101 ether, address(this), block.timestamp
        );
    }

    // ---------------------------------------------------------------------
    // swap
    // ---------------------------------------------------------------------

    function test_Swap() public {
        _add(100 ether, 100 ether);
        tokenA.mint(alice, 10 ether);

        uint256 amountIn = 10 ether;
        uint256 expectedOut = (amountIn * 997 * 100 ether) / (100 ether * 1000 + amountIn * 997);
        vm.startPrank(alice);
        tokenA.approve(address(v2Router), amountIn);
        (uint256 reserve0, uint256 reserve1) = _reserves();
        uint256 amountOut = _swap(address(tokenA), address(tokenB), amountIn, alice);
        vm.stopPrank();
        (uint256 newReserve0, uint256 newReserve1) = _reserves();
        assertEq(amountOut, expectedOut);
        assertEq(tokenA.balanceOf(alice), 0);
        assertEq(tokenB.balanceOf(alice), amountOut);
        assertEq(newReserve0, reserve0 + amountIn);
        assertEq(newReserve1, reserve1 - amountOut);
        assertEq(tokenA.balanceOf(address(v2Router)), 0);
        assertEq(tokenB.balanceOf(address(v2Router)), 0);
    }

    function test_Swap_Reverse_Direction() public {
        _add(100 ether, 100 ether);
        tokenB.mint(alice, 10 ether);
        uint256 amountIn = 10 ether;

        vm.startPrank(alice);
        tokenB.approve(address(v2Router), amountIn);
        uint256 amountOut = _swap(address(tokenB), address(tokenA), amountIn, alice);
        vm.stopPrank();
        assertEq(tokenA.balanceOf(alice), amountOut);
        assertEq(tokenB.balanceOf(alice), 0);
    }

    function test_Swap_RevertsBelowAmountOfMin() public {
        _add(100 ether, 100 ether);
        tokenA.mint(alice, 10 ether);

        uint256 amountIn = 10 ether;
        uint256 expectedOut = (amountIn * 997 * 100 ether) / (100 ether * 1000 + amountIn * 997);

        tokenA.approve(address(v2Router), amountIn);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        vm.expectRevert();
        v2Router.swapExactTokensForTokens(amountIn, expectedOut + 1, path, alice, block.timestamp);
    }

    function test_Swap_PriceImpact() public {
        _add(100 ether, 100 ether);
        tokenA.mint(alice, 10 ether);

        uint256 smallIn = 1 ether;
        uint256 expectedOut = (smallIn * 997 * 100 ether) / (100 ether * 1000 + smallIn * 997);
        (uint256 reserveA, uint256 reserveB) = _reserves();
        // Save the 100/100 pool so the large swap below starts from the same state.
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(alice);
        tokenA.approve(address(v2Router), smallIn);
        uint256 smallOut = _swap(address(tokenA), address(tokenB), smallIn, alice);
        vm.stopPrank();

        assertEq(smallOut, expectedOut);
        assertLt(smallOut * reserveA, smallIn * reserveB);

        vm.revertToState(snapshot);
        uint256 largeIn = 50 ether;
        uint256 largeOut = _swap(address(tokenA), address(tokenB), largeIn, address(this));

        emit log_named_decimal_uint("small rate", smallOut * 1e18 / smallIn, 18);
        emit log_named_decimal_uint("large rate", largeOut * 1e18 / largeIn, 18);
        // largeOut / largeIn < smallOut / smallIn, cross-multiplied
        assertLt(largeOut * smallIn, smallOut * largeIn);
    }

    // ---------------------------------------------------------------------
    // removeLiquidity
    // ---------------------------------------------------------------------
    function test_RemoveLiquidity() public {
        (,, uint256 liquidity) = _add(100 ether, 400 ether);
        IUniswapV2Pair pair = _pair();
        (uint256 reserveA, uint256 reserveB) = _reserves();
        uint256 totalSupply = pair.totalSupply();

        uint256 expectedA = liquidity * reserveA / totalSupply;
        uint256 expectedB = liquidity * reserveB / totalSupply;

        uint256 balanceA = tokenA.balanceOf(alice);
        uint256 balanceB = tokenB.balanceOf(alice);

        pair.approve(address(v2Router), liquidity);
        (uint256 a, uint256 b) = _remove(address(tokenA), address(tokenB), liquidity, alice);

        assertEq(a, expectedA);
        assertEq(b, expectedB);
        assertEq(a, 100 ether - 500);
        assertEq(b, 400 ether - 2000);

        assertEq(pair.totalSupply(), MINIMUM_LIQUIDITY);

        (uint256 newReserveA, uint256 newReserveB) = _reserves();
        assertEq(newReserveA, reserveA - a);
        assertEq(newReserveB, reserveB - b);

        assertEq(tokenA.balanceOf(alice), balanceA + a);
        assertEq(tokenB.balanceOf(alice), balanceB + b);
    }

    // ---------------------------------------------------------------------
    // TWAP
    // ---------------------------------------------------------------------
    function test_TWAP() public {
        _add(100 ether, 400 ether);
        IUniswapV2Pair pair = _pair();

        uint256 c0 = pair.price0CumulativeLast();
        uint256 t0 = block.timestamp;
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 priceBefore = (uint256(r1) << 112) / r0;

        vm.warp(block.timestamp + 10 minutes);
        _swap(address(tokenA), address(tokenB), 10 ether, address(this));

        (r0, r1,) = pair.getReserves();
        uint256 priceAfter = (uint256(r1) << 112) / r0;

        vm.warp(block.timestamp + 10 minutes);
        pair.sync();

        uint256 c1 = pair.price0CumulativeLast();
        uint256 twap = (c1 - c0) / (block.timestamp - t0);

        uint256 expected = (priceBefore * 10 minutes + priceAfter * 10 minutes) / 20 minutes;
        assertEq(expected, twap);

        uint256 lo = priceBefore < priceAfter ? priceBefore : priceAfter;
        uint256 hi = priceBefore < priceAfter ? priceAfter : priceBefore;
        assertGt(twap, lo);
        assertLt(twap, hi);
    }
}
