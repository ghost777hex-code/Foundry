// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/// @notice Simple TWAP (time-weighted average price) oracle for one Uniswap v2 pair.
///
/// The pair keeps a running sum: priceCumulative += price × seconds.
/// If we save that sum at two moments, the average price between them is
///
///     TWAP = (cumulativeNow − cumulativeThen) / (timeNow − timeThen)
///
/// Prices in the pair are UQ112x112 fixed point (real price × 2^112).
/// This contract returns prices scaled by 1e18 instead, which is easier to read.
contract UniswapV2Twap {
    error NotEnoughHistory();

    struct Snapshot {
        uint256 timestamp;
        uint256 price0Cumulative; // price of token0 in token1, summed over time
        uint256 price1Cumulative; // price of token1 in token0, summed over time
    }

    IUniswapV2Pair public immutable pair;

    /// @dev Saved cumulative prices, oldest first.
    Snapshot[] public snapshots;

    constructor(IUniswapV2Pair pair_) {
        pair = pair_;
    }

    // ---------------------------------------------------------------------
    // 1. Store cumulative prices
    // ---------------------------------------------------------------------

    /// @notice Saves the current cumulative prices. Call it regularly (e.g. every few minutes).
    function update() external {
        (uint256 price0Cumulative, uint256 price1Cumulative) = currentCumulativePrices();
        snapshots.push(Snapshot(block.timestamp, price0Cumulative, price1Cumulative));
    }

    /// @notice The pair's cumulative prices right now.
    /// The pair only updates its sums on swap/mint/burn/sync, so we add the part since its last update:
    /// current price × seconds since then.
    function currentCumulativePrices() public view returns (uint256 price0Cumulative, uint256 price1Cumulative) {
        price0Cumulative = pair.price0CumulativeLast();
        price1Cumulative = pair.price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 lastUpdate) = pair.getReserves();
        unchecked {
            // Same math as the pair; uint32 time and the sums are allowed to overflow (wrap around).
            uint32 elapsed = uint32(block.timestamp) - lastUpdate;
            price0Cumulative += (uint256(reserve1) << 112) / reserve0 * elapsed;
            price1Cumulative += (uint256(reserve0) << 112) / reserve1 * elapsed;
        }
    }

    // ---------------------------------------------------------------------
    // 2. TWAP
    // ---------------------------------------------------------------------

    /// @notice Average prices over the last 30 minutes, scaled by 1e18.
    function twap30Min() external view returns (uint256 price0, uint256 price1) {
        return twap(30 minutes);
    }

    /// @notice Average prices over the last 10 minutes, scaled by 1e18.
    function twap10Min() external view returns (uint256 price0, uint256 price1) {
        return twap(10 minutes);
    }

    /// @notice Average prices over the last `period` seconds, scaled by 1e18.
    /// price0 = token0 in token1, price1 = token1 in token0.
    function twap(uint256 period) public view returns (uint256 price0, uint256 price1) {
        Snapshot memory old = _snapshotOlderThan(period);
        (uint256 price0CumulativeNow, uint256 price1CumulativeNow) = currentCumulativePrices();
        uint256 timeElapsed = block.timestamp - old.timestamp;

        uint256 price0Average; // UQ112x112
        uint256 price1Average; // UQ112x112
        unchecked {
            // Even if a sum wrapped around, the wrapping subtraction gives the right difference.
            price0Average = (price0CumulativeNow - old.price0Cumulative) / timeElapsed;
            price1Average = (price1CumulativeNow - old.price1Cumulative) / timeElapsed;
        }

        // UQ112x112 → 1e18 scale: × 1e18 / 2^112
        price0 = Math.mulDiv(price0Average, 1e18, 1 << 112);
        price1 = Math.mulDiv(price1Average, 1e18, 1 << 112);
    }

    /// @notice Spot price right now (no averaging), scaled by 1e18. Handy to compare with the TWAP.
    function spot() external view returns (uint256 price0, uint256 price1) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        price0 = uint256(reserve1) * 1e18 / reserve0;
        price1 = uint256(reserve0) * 1e18 / reserve1;
    }

    function snapshotCount() external view returns (uint256) {
        return snapshots.length;
    }

    /// @dev Newest snapshot taken at least `period` seconds ago.
    function _snapshotOlderThan(uint256 period) internal view returns (Snapshot memory) {
        for (uint256 i = snapshots.length; i > 0; i--) {
            Snapshot memory s = snapshots[i - 1];
            if (s.timestamp + period <= block.timestamp) return s;
        }
        revert NotEnoughHistory();
    }
}
