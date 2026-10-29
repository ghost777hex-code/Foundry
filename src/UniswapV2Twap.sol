// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/// @notice TWAP oracle for one Uniswap v2 pair.
/// The pair keeps `priceXCumulativeLast` = sum of (price × seconds), in UQ112x112 fixed point.
/// This contract stores snapshots of those cumulative prices; the average price between two
/// snapshots is (cumulative₂ − cumulative₁) / (time₂ − time₁).
contract UniswapV2Twap {
    error InvalidToken();
    error InvalidPeriod();
    error NoReserves();
    error NotEnoughHistory();

    struct Observation {
        uint64 timestamp;
        uint256 price0Cumulative; // token1 per token0, UQ112x112 × seconds
        uint256 price1Cumulative; // token0 per token1, UQ112x112 × seconds
    }

    uint256 public constant TWAP_30_MIN = 30 minutes;
    uint256 public constant TWAP_10_MIN = 10 minutes;

    IUniswapV2Pair public immutable pair;
    address public immutable token0;
    address public immutable token1;

    /// @dev Snapshots of the pair's cumulative prices, oldest first.
    Observation[] public observations;

    constructor(IUniswapV2Pair pair_) {
        pair = pair_;
        token0 = pair_.token0();
        token1 = pair_.token1();
    }

    // ---------------------------------------------------------------------
    // Store cumulative prices
    // ---------------------------------------------------------------------

    /// @notice Saves the current cumulative prices. Call it regularly (e.g. every few minutes from a keeper);
    /// a TWAP over N minutes needs a snapshot that is at least N minutes old.
    function update() external {
        uint256 count = observations.length;
        // At most one snapshot per block: a second one in the same second adds no information.
        if (count > 0 && observations[count - 1].timestamp == block.timestamp) return;

        (uint256 price0Cumulative, uint256 price1Cumulative) = currentCumulativePrices();
        observations.push(Observation(uint64(block.timestamp), price0Cumulative, price1Cumulative));
    }

    /// @notice The pair's cumulative prices as of this block.
    /// The pair only updates its accumulators on swap/mint/burn/sync, so if nothing happened yet in this
    /// block we add (current price × seconds since the pair's last update) ourselves, without calling sync().
    function currentCumulativePrices() public view returns (uint256 price0Cumulative, uint256 price1Cumulative) {
        price0Cumulative = pair.price0CumulativeLast();
        price1Cumulative = pair.price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert NoReserves();

        unchecked {
            // Same arithmetic as the pair: uint32 timestamps and accumulators are allowed to wrap around.
            uint32 timeElapsed = uint32(block.timestamp) - blockTimestampLast;
            if (timeElapsed > 0) {
                price0Cumulative += (uint256(reserve1) << 112) / reserve0 * timeElapsed;
                price1Cumulative += (uint256(reserve0) << 112) / reserve1 * timeElapsed;
            }
        }
    }

    // ---------------------------------------------------------------------
    // TWAP
    // ---------------------------------------------------------------------

    /// @notice 30-minute TWAP: how much of the other token `amountIn` of `tokenIn` is worth.
    function twap30Min(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        return consult(tokenIn, amountIn, TWAP_30_MIN);
    }

    /// @notice 10-minute TWAP: how much of the other token `amountIn` of `tokenIn` is worth.
    function twap10Min(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        return consult(tokenIn, amountIn, TWAP_10_MIN);
    }

    /// @notice Average price over (at least) the last `period` seconds, applied to `amountIn` of `tokenIn`.
    /// Uses the newest snapshot that is at least `period` old, so the actual window is `period` or a bit longer.
    function consult(address tokenIn, uint256 amountIn, uint256 period) public view returns (uint256 amountOut) {
        if (tokenIn != token0 && tokenIn != token1) revert InvalidToken();
        if (period == 0) revert InvalidPeriod();
        if (block.timestamp < period) revert NotEnoughHistory();

        Observation memory past = _observationAtOrBefore(block.timestamp - period);
        (uint256 price0Cumulative, uint256 price1Cumulative) = currentCumulativePrices();
        uint256 timeElapsed = block.timestamp - past.timestamp;

        uint256 priceAverage; // UQ112x112
        unchecked {
            // Accumulators may have wrapped; wrapping subtraction still gives the right difference.
            priceAverage = tokenIn == token0
                ? (price0Cumulative - past.price0Cumulative) / timeElapsed
                : (price1Cumulative - past.price1Cumulative) / timeElapsed;
        }
        // UQ112x112 → plain number: multiply, then divide by 2^112.
        amountOut = Math.mulDiv(priceAverage, amountIn, 1 << 112);
    }

    /// @notice Spot price right now (no averaging), for comparison with the TWAP.
    function spot(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (tokenIn == token0) return amountIn * reserve1 / reserve0;
        if (tokenIn == token1) return amountIn * reserve0 / reserve1;
        revert InvalidToken();
    }

    function observationCount() external view returns (uint256) {
        return observations.length;
    }

    /// @dev Binary search for the newest snapshot with timestamp <= `target`.
    function _observationAtOrBefore(uint256 target) private view returns (Observation memory) {
        uint256 count = observations.length;
        if (count == 0 || observations[0].timestamp > target) revert NotEnoughHistory();

        uint256 low = 0;
        uint256 high = count - 1;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (observations[mid].timestamp <= target) low = mid;
            else high = mid - 1;
        }
        return observations[low];
    }
}
