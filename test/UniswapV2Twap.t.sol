// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {UniswapV2} from "../src/UniswapV2.sol";
import {UniswapV2Twap} from "../src/UniswapV2Twap.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {UniswapDeployer} from "./utils/UniswapDeployer.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {Test} from "forge-std/Test.sol";

/// Timeline used by most tests (price = how many B one A is worth):
///
///   T0 ─────── 20 min, price 1 ─────── T0+20m ─── 10 min, price 2 ─── T0+30m
///   update()                           price → 2, update()             read TWAPs
///
///   30-min TWAP = (20 × 1 + 10 × 2) / 30 = 1.3333
///   10-min TWAP = (10 × 2) / 10           = 2
contract UniswapV2TwapTest is Test, UniswapDeployer {
    UniswapV2 public uni;
    UniswapV2Twap public twap;
    IUniswapV2Pair public pair;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    uint256 public t0;

    function setUp() public {
        deployUniswap(address(this));
        uni = new UniswapV2(v2Factory);

        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000 ether);
        tokenA.approve(address(uni), type(uint256).max);
        tokenB.approve(address(uni), type(uint256).max);

        // Pool 1000 A / 1000 B => 1 A = 1 B
        uni.addLiquidity(address(tokenA), address(tokenB), 1000 ether, 1000 ether, 0, 0, address(this));
        pair = IUniswapV2Pair(v2Factory.getPair(address(tokenA), address(tokenB)));

        twap = new UniswapV2Twap(pair);
        t0 = block.timestamp;
    }

    /// Doubles the price of A (1 A = 2 B) by adding B to the pair and syncing reserves.
    function _doublePriceOfA() internal {
        tokenB.transfer(address(pair), 1000 ether);
        pair.sync(); // reserves: 1000 A / 2000 B
    }

    function _runTimeline() internal {
        twap.update(); // snapshot at T0
        vm.warp(t0 + 20 minutes);
        _doublePriceOfA();
        twap.update(); // snapshot at T0+20m
        vm.warp(t0 + 30 minutes);
    }

    // ---------------------------------------------------------------------
    // Storing cumulative prices
    // ---------------------------------------------------------------------

    function test_Update_StoresCumulativePrices() public {
        twap.update();
        vm.warp(t0 + 10 minutes);
        twap.update();

        (uint64 ts0, uint256 c0,) = twap.observations(0);
        (uint64 ts1, uint256 c1,) = twap.observations(1);

        assertEq(ts0, t0);
        assertEq(ts1, t0 + 10 minutes);
        // Price 1 (= 2^112 in UQ112x112) for 600 seconds.
        assertEq(c1 - c0, (uint256(1) << 112) * 600);
    }

    function test_Update_OncePerBlock() public {
        twap.update();
        twap.update();
        twap.observations(0);
        vm.expectRevert(); // no second snapshot
        twap.observations(1);
    }

    // ---------------------------------------------------------------------
    // 30-min and 10-min TWAP
    // ---------------------------------------------------------------------

    function test_Twap30Min() public {
        _runTimeline();
        // (20 min × 1 + 10 min × 2) / 30 min = 4/3
        assertApproxEqAbs(twap.twap30Min(address(tokenA), 1 ether), uint256(4 ether) / 3, 1);
    }

    function test_Twap10Min() public {
        _runTimeline();
        // only the last 10 minutes, all at price 2
        assertApproxEqAbs(twap.twap10Min(address(tokenA), 1 ether), 2 ether, 1);
    }

    function test_Twap_OtherDirection() public {
        _runTimeline();
        // B in terms of A: 30 min = (20 × 1 + 10 × 0.5) / 30 = 0.8333, 10 min = 0.5
        assertApproxEqAbs(twap.twap30Min(address(tokenB), 1 ether), uint256(5 ether) / 6, 1);
        assertApproxEqAbs(twap.twap10Min(address(tokenB), 1 ether), 0.5 ether, 1);
    }

    function test_Twap_WithoutRecentPairActivity() public {
        twap.update();
        // Nobody trades for 30 minutes: the pair's own accumulator is stale,
        // but currentCumulativePrices() extends it to now.
        vm.warp(t0 + 30 minutes);
        assertApproxEqAbs(twap.twap30Min(address(tokenA), 1 ether), 1 ether, 1);
    }

    // ---------------------------------------------------------------------
    // Why TWAP: a one-block price manipulation barely moves it
    // ---------------------------------------------------------------------

    function test_Twap_ResistsSameBlockManipulation() public {
        _runTimeline();
        uint256 twap30Before = twap.twap30Min(address(tokenA), 1 ether);
        uint256 twap10Before = twap.twap10Min(address(tokenA), 1 ether);

        // Dump 9000 A into the pool in this block: spot price of A crashes.
        uni.swapExactTokensForTokens(address(tokenA), address(tokenB), 9000 ether, 0, address(this));

        assertLt(twap.spot(address(tokenA), 1 ether), 0.03 ether); // spot: 2 → ~0.02
        // The new price has existed for 0 seconds, so it has no weight in the average yet.
        assertEq(twap.twap30Min(address(tokenA), 1 ether), twap30Before);
        assertEq(twap.twap10Min(address(tokenA), 1 ether), twap10Before);
    }

    // ---------------------------------------------------------------------
    // Not enough history
    // ---------------------------------------------------------------------

    function test_Twap30Min_RevertsWithOnly20MinOfHistory() public {
        twap.update();
        vm.warp(t0 + 20 minutes);

        twap.twap10Min(address(tokenA), 1 ether); // fine: a 20-min-old snapshot exists
        vm.expectRevert();
        twap.twap30Min(address(tokenA), 1 ether);
    }

    function test_Consult_RevertsWithoutSnapshots() public {
        vm.warp(t0 + 1 hours);
        vm.expectRevert();
        twap.twap10Min(address(tokenA), 1 ether);
    }

    function test_Consult_RevertsOnUnknownToken() public {
        _runTimeline();
        vm.expectRevert();
        twap.twap10Min(address(0xdead), 1 ether);
    }
}
