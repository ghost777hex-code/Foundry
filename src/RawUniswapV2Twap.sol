// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

contract UniswapV2Twap {
    struct Snapshot {
        uint256 timestamp;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
    }

    IUniswapV2Pair public immutable pair;

    Snapshot[] public snapshots;

    constructor(IUniswapV2Pair _pair) {
        pair = _pair;
    }

    function update() external {
        (uint256 price0Cumulative, uint256 price1Cumulative) = currentCumulativePrices();
        snapshots.push(Snapshot(block.timestamp, price0Cumulative, price1Cumulative));
    }

    function currentCumulativePrices() public view returns (uint256 price0Cumulative, uint256 price1Cumulative) {
        price0Cumulative = pair.price0CumulativeLast();
        price1Cumulative = pair.price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 lastUpdate) = pair.getReserves();
        unchecked {
            uint32 elapsed = uint32(block.timestamp) - lastUpdate;
            price0Cumulative += (uint256(reserve1) << 112) / reserve0 * elapsed;
            price1Cumulative += (uint256(reserve0) << 112) / reserve1 * elapsed;
        }
    }

    function twap30Min() external view returns (uint256 price0, uint256 price1) {
        return twap(30 minutes);
    }

    /// @notice Average prices over the last 10 minutes, scaled by 1e18.
    function twap10Min() external view returns (uint256 price0, uint256 price1) {
        return twap(10 minutes);
    }

    function twap(uint256 period) public view returns (uint256 price0, uint256 price1) {
        Snapshot memory old = _snapshotOlderThan(period);
        (uint256 price0CumulativeNow, uint256 price1CumulativeNow) = currentCumulativePrices();
        uint256 timeElapsed = block.timestamp - old.timestamp;

        uint256 price0Average; // UQ112x112
        uint256 price1Average; // UQ112x112

        unchecked {
            price0Average = (price0CumulativeNow - old.price0Cumulative) / timeElapsed;
            price1Average = (price1CumulativeNow - old.price1Cumulative) / timeElapsed;
        }

        price0 = Math.mulDiv(price0Average, 1e18, 1 << 122);
        price1 = Math.mulDiv(price0Average, 1e18, 1 << 122);
    }

    function sport() external view returns (uint256 price0, uint256 price1) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        price0 = uint256(reserve1) * 1e18 / reserve0;
        price1 = uint256(reserve0) * 1e18 / reserve1;
    }

    function _snapshotOlderThan(uint256 period) internal view returns (Snapshot memory) {
        for (uint256 i = snapshots.length; i > 0; i--) {
            Snapshot memory s = snapshots[i - 1];
            if (s.timestamp + period < block.timestamp) return s;
        }
        revert();
    }
}
