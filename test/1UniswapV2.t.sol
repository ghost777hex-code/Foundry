// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {UniswapV2} from "../src/UniswapV2.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {UniswapDeployer} from "./utils/UniswapDeployer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV2Callee} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Tests src/UniswapV2.sol against the real v2 factory/pair. The router is never used.
contract UniswapV2Test is Test, UniswapDeployer, IUniswapV2Callee {
    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    UniswapV2 public uni;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public alice = makeAddr("alice");

    /// @dev How much tokenA uniswapV2Call pays back during a flash swap test.
    uint256 internal flashRepay;

    function setUp() public {
        deployUniswap(address(this));
        uni = new UniswapV2(v2Factory);
        vm.label(address(uni), "UniswapV2");

        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000 ether);

        tokenA.approve(address(uni), type(uint256).max);
        tokenB.approve(address(uni), type(uint256).max);
    }

    function _add(uint256 amountA, uint256 amountB) internal returns (uint256 a, uint256 b, uint256 liquidity) {
        return uni.addLiquidity(address(tokenA), address(tokenB), amountA, amountB, 0, 0, address(this));
    }

    function _pair() internal view returns (IUniswapV2Pair) {
        return IUniswapV2Pair(v2Factory.getPair(address(tokenA), address(tokenB)));
    }

    function _reserves() internal view returns (uint256 reserveA, uint256 reserveB) {
        (uint112 r0, uint112 r1,) = _pair().getReserves();
        (reserveA, reserveB) = address(tokenA) < address(tokenB) ? (r0, r1) : (r1, r0);
    }

    // ---------------------------------------------------------------------
    // addLiquidity
    // ---------------------------------------------------------------------

    function test_AddLiquidity() public {
        assertEq(v2Factory.getPair(address(tokenA), address(tokenB)), address(0));

        (uint256 a, uint256 b, uint256 liquidity) = _add(1000 ether, 1000 ether);

        IUniswapV2Pair pair = _pair();
        assertTrue(address(pair) != address(0));
        assertEq(a, 1000 ether);
        assertEq(b, 1000 ether);
        // First LP = sqrt(a * b) - MINIMUM_LIQUIDITY (locked forever at address(0))
        assertEq(liquidity, 1000 ether - MINIMUM_LIQUIDITY);
        assertEq(pair.balanceOf(address(this)), liquidity);
        assertEq(pair.balanceOf(address(0)), MINIMUM_LIQUIDITY);

        (uint256 reserveA, uint256 reserveB) = _reserves();
        assertEq(reserveA, 1000 ether);
        assertEq(reserveB, 1000 ether);
    }

    function test_AddLiquidity_MintsToRecepient() public {
        (,, uint256 liquidity) = uni.addLiquidity(address(tokenA), address(tokenB), 1000 ether, 1000 ether, 0, 0, alice);
        assertEq(_pair().balanceOf(alice), liquidity);
        assertEq(_pair().balanceOf(address(this)), 0);
    }

    /// Pool is 1:2 and A is the limiting side: all of A is used, B is cut down to match.
    function test_AddLiquidity_TokenALimited() public {
        _add(1000 ether, 2000 ether);
        (uint256 a, uint256 b,) = _add(100 ether, 500 ether);
        assertEq(a, 100 ether);
        assertEq(b, 200 ether);
    }

    /// Pool is 1:2 and B is the limiting side: all of B is used, A is cut down to match.
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
        uni.addLiquidity(address(tokenA), address(tokenB), 100 ether, 500 ether, 0, 101 ether, address(this));
    }

    // ---------------------------------------------------------------------
    // swap (callback)
    // ---------------------------------------------------------------------

    function test_Swap() public {
        _add(1000 ether, 1000 ether);
        tokenA.mint(alice, 10 ether);

        // 10 A in, 0.3% fee, 1000/1000 pool => ~9.87 B out
        uint256 amountIn = 10 ether;
        uint256 expectedOut = (amountIn * 997 * 1000 ether) / (1000 ether * 1000 + amountIn * 997);

        vm.startPrank(alice);
        tokenA.approve(address(uni), amountIn);
        uint256 amountOut = uni.swapExactTokensForTokens(address(tokenA), address(tokenB), amountIn, 0, alice);
        vm.stopPrank();

        assertEq(amountOut, expectedOut);
        assertEq(tokenA.balanceOf(alice), 0);
        assertEq(tokenB.balanceOf(alice), expectedOut);
        // Nothing is left behind in our contract.
        assertEq(tokenA.balanceOf(address(uni)), 0);
        assertEq(tokenB.balanceOf(address(uni)), 0);

        (uint256 reserveA, uint256 reserveB) = _reserves();
        assertEq(reserveA, 1010 ether);
        assertEq(reserveB, 1000 ether - expectedOut);
    }

    function test_Swap_ReverseDirection() public {
        _add(1000 ether, 1000 ether);
        tokenB.mint(alice, 10 ether);

        vm.startPrank(alice);
        tokenB.approve(address(uni), 10 ether);
        uint256 amountOut = uni.swapExactTokensForTokens(address(tokenB), address(tokenA), 10 ether, 0, alice);
        vm.stopPrank();

        assertEq(amountOut, uni.getAmountOut(10 ether, 1000 ether, 1000 ether));
        assertEq(tokenA.balanceOf(alice), amountOut);
    }

    function test_Swap_RevertsBelowAmountOutMin() public {
        _add(1000 ether, 1000 ether);
        uint256 expectedOut = uni.getAmountOut(10 ether, 1000 ether, 1000 ether);

        vm.expectRevert();
        uni.swapExactTokensForTokens(address(tokenA), address(tokenB), 10 ether, expectedOut + 1, address(this));
    }

    /// A fake pair calls our callback directly to pull tokens from someone who approved us.
    function test_Callback_RevertsFromFakePair() public {
        _add(1000 ether, 1000 ether);
        tokenA.mint(alice, 100 ether);
        vm.prank(alice);
        tokenA.approve(address(uni), type(uint256).max);

        bytes memory data = abi.encode(UniswapV2.CallbackData(address(tokenA), address(tokenB), 100 ether, alice));
        vm.expectRevert();
        uni.uniswapV2Call(address(uni), 0, 0, data);
    }

    /// Someone calls the real pair's swap with `to = uni`, so the real pair triggers our callback.
    function test_Callback_RevertsWhenSwapNotStartedByUs() public {
        _add(1000 ether, 1000 ether);
        tokenA.mint(alice, 100 ether);
        vm.prank(alice);
        tokenA.approve(address(uni), type(uint256).max);

        bytes memory data = abi.encode(UniswapV2.CallbackData(address(tokenA), address(tokenB), 100 ether, alice));
        (uint256 out0, uint256 out1) =
            address(tokenA) < address(tokenB) ? (uint256(0), uint256(1 ether)) : (uint256(1 ether), uint256(0));
        IUniswapV2Pair pair = _pair();
        vm.expectRevert();
        pair.swap(out0, out1, address(uni), data);
    }

    // ---------------------------------------------------------------------
    // removeLiquidity
    // ---------------------------------------------------------------------

    function test_RemoveLiquidity() public {
        (,, uint256 liquidity) = _add(1000 ether, 1000 ether);
        uint256 balA = tokenA.balanceOf(address(this));
        uint256 balB = tokenB.balanceOf(address(this));

        // Approve the LP token (the pair itself), not tokenA/tokenB.
        _pair().approve(address(uni), liquidity);
        (uint256 a, uint256 b) = uni.removeLiquidity(address(tokenA), address(tokenB), liquidity, 0, 0, address(this));

        // Everything comes back except what backs the MINIMUM_LIQUIDITY locked at address(0).
        assertEq(a, 1000 ether - MINIMUM_LIQUIDITY);
        assertEq(b, 1000 ether - MINIMUM_LIQUIDITY);
        assertEq(tokenA.balanceOf(address(this)), balA + a);
        assertEq(tokenB.balanceOf(address(this)), balB + b);
        assertEq(_pair().balanceOf(address(this)), 0);
    }

    function test_RemoveLiquidity_Half() public {
        (,, uint256 liquidity) = _add(1000 ether, 4000 ether);

        _pair().approve(address(uni), liquidity / 2);
        (uint256 a, uint256 b) =
            uni.removeLiquidity(address(tokenA), address(tokenB), liquidity / 2, 0, 0, address(this));

        // Half the LP => half of each reserve (minus dust from MINIMUM_LIQUIDITY).
        assertApproxEqAbs(a, 500 ether, 1e6);
        assertApproxEqAbs(b, 2000 ether, 1e6);
        assertEq(_pair().balanceOf(address(this)), liquidity - liquidity / 2);
    }

    function test_RemoveLiquidity_ToRecipient() public {
        (,, uint256 liquidity) = _add(1000 ether, 1000 ether);

        _pair().approve(address(uni), liquidity);
        (uint256 a, uint256 b) = uni.removeLiquidity(address(tokenA), address(tokenB), liquidity, 0, 0, alice);

        assertEq(tokenA.balanceOf(alice), a);
        assertEq(tokenB.balanceOf(alice), b);
    }

    function test_RemoveLiquidity_ReversedTokenOrder() public {
        (,, uint256 liquidity) = _add(1000 ether, 4000 ether);

        // Passing (B, A) must return amounts in (B, A) order.
        _pair().approve(address(uni), liquidity / 2);
        (uint256 b, uint256 a) =
            uni.removeLiquidity(address(tokenB), address(tokenA), liquidity / 2, 0, 0, address(this));

        assertApproxEqAbs(a, 500 ether, 1e6);
        assertApproxEqAbs(b, 2000 ether, 1e6);
    }

    function test_RemoveLiquidity_IncludesSwapFees() public {
        (,, uint256 liquidity) = _add(1000 ether, 1000 ether);

        // Someone swaps 100 A -> B; the 0.3% fee stays in the pool.
        tokenA.mint(alice, 100 ether);
        vm.startPrank(alice);
        tokenA.approve(address(uni), 100 ether);
        uni.swapExactTokensForTokens(address(tokenA), address(tokenB), 100 ether, 0, alice);
        vm.stopPrank();

        _pair().approve(address(uni), liquidity);
        (uint256 a, uint256 b) = uni.removeLiquidity(address(tokenA), address(tokenB), liquidity, 0, 0, address(this));

        // k grew from the fee, so the LP gets back more value than it put in.
        assertGt(a * b, (1000 ether - MINIMUM_LIQUIDITY) ** 2);
    }

    function test_RemoveLiquidity_RevertsWithoutLPApproval() public {
        (,, uint256 liquidity) = _add(1000 ether, 1000 ether);
        vm.expectRevert();
        uni.removeLiquidity(address(tokenA), address(tokenB), liquidity, 0, 0, address(this));
    }

    function test_RemoveLiquidity_RevertsBelowMin() public {
        (,, uint256 liquidity) = _add(1000 ether, 1000 ether);
        _pair().approve(address(uni), liquidity);
        vm.expectRevert();
        uni.removeLiquidity(address(tokenA), address(tokenB), liquidity, 1000 ether, 0, address(this));
    }

    function test_RemoveLiquidity_RevertsWhenPairMissing() public {
        vm.expectRevert();
        uni.removeLiquidity(address(tokenA), address(tokenB), 1 ether, 0, 0, address(this));
    }

    // ---------------------------------------------------------------------
    // swap math: k, price impact, getAmountOut / amountIn bounds
    // ---------------------------------------------------------------------

    function test_Swap_KGrows() public {
        _add(1000 ether, 1000 ether);
        (uint256 reserveA, uint256 reserveB) = _reserves();
        uint256 kBefore = reserveA * reserveB;

        uni.swapExactTokensForTokens(address(tokenA), address(tokenB), 100 ether, 0, address(this));

        // The 0.3% fee stays in the pool, so x * y ends up larger than before the swap.
        (reserveA, reserveB) = _reserves();
        assertGt(reserveA * reserveB, kBefore);
    }

    /// 100x the input gives less than 100x the output: the bigger the trade, the worse the average price.
    function test_Swap_PriceImpact() public {
        _add(1000 ether, 1000 ether);

        uint256 snapshot = vm.snapshotState();
        uint256 outSmall = uni.swapExactTokensForTokens(address(tokenA), address(tokenB), 1 ether, 0, address(this));
        vm.revertToState(snapshot);
        uint256 outLarge = uni.swapExactTokensForTokens(address(tokenA), address(tokenB), 100 ether, 0, address(this));

        // Spot price is 1 B per A. 1 A in: ~0.4% worse (almost only the fee). 100 A in: ~9.3% worse.
        assertEq(outSmall, 996_006_981_039_903_216);
        assertEq(outLarge, 90_661_089_388_014_913_158);
        assertLt(outLarge, outSmall * 100);
    }

    /// getAmountOut is the most the pair will give: asking for 1 wei more fails the K check.
    function test_GetAmountOut_IsMaximum() public {
        _add(1000 ether, 1000 ether);
        IUniswapV2Pair pair = _pair();
        uint256 amountOut = uni.getAmountOut(10 ether, 1000 ether, 1000 ether);

        // Swap on the pair directly: pay first, then call swap with empty data (no callback).
        tokenA.transfer(address(pair), 10 ether);
        vm.expectRevert(bytes("UniswapV2: K"));
        _pairSwapOutB(pair, amountOut + 1);

        _pairSwapOutB(pair, amountOut);
        (, uint256 reserveB) = _reserves();
        assertEq(reserveB, 1000 ether - amountOut);
    }

    /// amountIn = reserveIn * amountOut * 1000 / ((reserveOut - amountOut) * 997) + 1 is the least the pair accepts.
    function test_AmountIn_IsMinimum() public {
        _add(1000 ether, 1000 ether);
        IUniswapV2Pair pair = _pair();
        uint256 amountOut = 10 ether;
        uint256 amountIn = (1000 ether * amountOut * 1000) / ((1000 ether - amountOut) * 997) + 1;

        uint256 snapshot = vm.snapshotState();
        tokenA.transfer(address(pair), amountIn - 1);
        vm.expectRevert(bytes("UniswapV2: K"));
        _pairSwapOutB(pair, amountOut);
        vm.revertToState(snapshot);

        tokenA.transfer(address(pair), amountIn);
        _pairSwapOutB(pair, amountOut);
        (uint256 reserveA,) = _reserves();
        assertEq(reserveA, 1000 ether + amountIn);
    }

    function _pairSwapOutB(IUniswapV2Pair pair, uint256 amountOut) internal {
        (uint256 out0, uint256 out1) =
            address(tokenA) < address(tokenB) ? (uint256(0), amountOut) : (amountOut, uint256(0));
        pair.swap(out0, out1, address(this), "");
    }

    // ---------------------------------------------------------------------
    // flash swap (this test contract is the callee)
    // ---------------------------------------------------------------------

    /// Borrow A and repay A: the pair only needs 997 * repay >= 1000 * borrowed.
    function test_FlashSwap() public {
        _add(1000 ether, 1000 ether);
        IUniswapV2Pair pair = _pair();
        uint256 borrowed = 100 ether;
        uint256 repay = Math.ceilDiv(borrowed * 1000, 997);

        _flashBorrowA(pair, borrowed, repay);

        // The pool keeps the fee; B is untouched.
        (uint256 reserveA, uint256 reserveB) = _reserves();
        assertEq(reserveA, 1000 ether - borrowed + repay);
        assertEq(reserveB, 1000 ether);
    }

    function test_FlashSwap_RevertsWhenUnderpaid() public {
        _add(1000 ether, 1000 ether);
        IUniswapV2Pair pair = _pair();
        uint256 borrowed = 100 ether;
        uint256 repay = Math.ceilDiv(borrowed * 1000, 997);

        vm.expectRevert(bytes("UniswapV2: K"));
        _flashBorrowA(pair, borrowed, repay - 1);
    }

    /// Returning exactly what was borrowed (no fee) is not enough either.
    function test_FlashSwap_RevertsWithoutFee() public {
        _add(1000 ether, 1000 ether);
        IUniswapV2Pair pair = _pair();
        vm.expectRevert(bytes("UniswapV2: K"));
        _flashBorrowA(pair, 100 ether, 100 ether);
    }

    function test_FlashSwap_RevertsWithoutRepay() public {
        _add(1000 ether, 1000 ether);
        IUniswapV2Pair pair = _pair();
        vm.expectRevert(bytes("UniswapV2: INSUFFICIENT_INPUT_AMOUNT"));
        _flashBorrowA(pair, 100 ether, 0);
    }

    /// @dev Takes the pair as a parameter: vm.expectRevert() applies to the next external call,
    /// so looking the pair up here (factory.getPair) would be the call it checks instead of swap.
    function _flashBorrowA(IUniswapV2Pair pair, uint256 amount, uint256 repay) internal {
        flashRepay = repay;
        (uint256 out0, uint256 out1) = address(tokenA) < address(tokenB) ? (amount, uint256(0)) : (uint256(0), amount);
        // Non-empty data turns the swap into a flash swap: the pair calls uniswapV2Call before checking K.
        pair.swap(out0, out1, address(this), abi.encode(amount));
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external override {
        assertEq(msg.sender, address(_pair()));
        assertEq(sender, address(this));
        // The pair has already sent the borrowed tokens before calling us.
        assertEq(amount0 + amount1, abi.decode(data, (uint256)));

        tokenA.transfer(msg.sender, flashRepay);
    }

    // ---------------------------------------------------------------------
    // protocol fee (feeTo)
    // ---------------------------------------------------------------------

    function test_ProtocolFee_OffByDefault() public {
        address feeTo = makeAddr("feeTo");
        _add(1000 ether, 1000 ether);
        uni.swapExactTokensForTokens(address(tokenA), address(tokenB), 100 ether, 0, address(this));
        _add(1 ether, 1 ether);

        assertEq(v2Factory.feeTo(), address(0));
        assertEq(_pair().kLast(), 0);
        assertEq(_pair().balanceOf(feeTo), 0);
    }

    /// With feeTo set, 1/6 of the growth in sqrt(k) is minted as LP to feeTo, on the next mint or burn.
    function test_ProtocolFee_On() public {
        address feeTo = makeAddr("feeTo");
        v2Factory.setFeeTo(feeTo); // works because setUp passed address(this) as feeToSetter

        _add(1000 ether, 1000 ether);
        IUniswapV2Pair pair = _pair();
        assertEq(pair.kLast(), 1000 ether * 1000 ether);

        uni.swapExactTokensForTokens(address(tokenA), address(tokenB), 100 ether, 0, address(this));
        // swap() never mints the fee; it is settled lazily.
        assertEq(pair.balanceOf(feeTo), 0);

        (uint256 reserveA, uint256 reserveB) = _reserves();
        uint256 rootK = Math.sqrt(reserveA * reserveB);
        uint256 rootKLast = Math.sqrt(pair.kLast());
        uint256 supply = pair.totalSupply();
        uint256 expectedFee = supply * (rootK - rootKLast) / (rootK * 5 + rootKLast);

        _add(1 ether, 1 ether);

        assertGt(expectedFee, 0);
        assertEq(pair.balanceOf(feeTo), expectedFee);
        // feeTo's share of the pool is worth 1/6 of the sqrt(k) growth.
        assertApproxEqRel(expectedFee * rootK / (supply + expectedFee), (rootK - rootKLast) / 6, 1e12);
    }

    // ---------------------------------------------------------------------
    // fuzz
    // ---------------------------------------------------------------------

    function testFuzz_Swap(uint256 amountIn, bool aToB) public {
        _add(1000 ether, 1000 ether);
        amountIn = bound(amountIn, 1000, 100_000 ether);
        (MockERC20 tokenIn, MockERC20 tokenOut) = aToB ? (tokenA, tokenB) : (tokenB, tokenA);
        (uint256 reserveA, uint256 reserveB) = _reserves();
        uint256 kBefore = reserveA * reserveB;
        uint256 expectedOut = (amountIn * 997 * 1000 ether) / (1000 ether * 1000 + amountIn * 997);

        uint256 amountOut =
            uni.swapExactTokensForTokens(address(tokenIn), address(tokenOut), amountIn, 0, address(this));

        assertEq(amountOut, expectedOut);
        (reserveA, reserveB) = _reserves();
        assertGe(reserveA * reserveB, kBefore);
    }

    /// Without swaps in between, adding then removing never returns more than was deposited.
    function testFuzz_AddRemove_NeverProfitable(uint256 amountA, uint256 amountB) public {
        _add(1000 ether, 3000 ether);
        amountA = bound(amountA, 1e6, 100_000 ether);
        amountB = bound(amountB, 1e6, 100_000 ether);

        (uint256 a, uint256 b, uint256 liquidity) = _add(amountA, amountB);
        _pair().approve(address(uni), liquidity);
        (uint256 aOut, uint256 bOut) =
            uni.removeLiquidity(address(tokenA), address(tokenB), liquidity, 0, 0, address(this));

        // Rounding always favors the pool.
        assertLe(aOut, a);
        assertLe(bOut, b);
    }

    function testFuzz_FlashSwap_MinimumRepay(uint256 borrowed) public {
        _add(1000 ether, 1000 ether);
        IUniswapV2Pair pair = _pair();
        borrowed = bound(borrowed, 1, 999 ether);
        uint256 repay = Math.ceilDiv(borrowed * 1000, 997);

        uint256 snapshot = vm.snapshotState();
        vm.expectRevert(bytes("UniswapV2: K"));
        _flashBorrowA(pair, borrowed, repay - 1);
        vm.revertToState(snapshot);

        _flashBorrowA(pair, borrowed, repay);
    }
}
