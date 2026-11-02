// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {UniswapV2Twap} from "../../src/UniswapV2Twap.sol";
import {Mainnet, MainnetForkTest} from "./MainnetFork.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/// @notice Runs src/UniswapV2Twap.sol against the live WETH/DAI pair.
/// DAI (0x6B..) < WETH (0xC0..), so token0 = DAI, token1 = WETH and price1 = DAI per 1 WETH.
///
/// Timeline (P = WETH price at the fork block):
///
///   T0 ──── 20 min, price P ──── T0+20m ── 10 min, price 2P ── T0+30m
///   update()                     price → 2P, update()          read TWAPs
///
///   30-min TWAP = (20 × P + 10 × 2P) / 30 = 4/3 P
///   10-min TWAP = (10 × 2P) / 10          = 2P
contract UniswapV2TwapForkTest is MainnetForkTest {
    IUniswapV2Pair public pair;
    UniswapV2Twap public twap;
    uint256 public t0;

    function setUp() public override {
        super.setUp();
        pair = IUniswapV2Pair(IUniswapV2Factory(Mainnet.V2_FACTORY).getPair(Mainnet.WETH, Mainnet.DAI));
        twap = new UniswapV2Twap(pair);
        t0 = block.timestamp;

        vm.label(address(pair), "WETH/DAI");
    }

    /// Doubles the WETH price: twice as much DAI in the pair, then sync() so the reserves follow.
    function _doubleWethPrice() internal {
        uint256 daiBalance = IERC20(Mainnet.DAI).balanceOf(address(pair));
        deal(Mainnet.DAI, address(pair), daiBalance * 2);
        pair.sync();
    }

    function test_Fork_Twap30MinAnd10Min() public {
        (, uint256 startPrice) = twap.spot(); // DAI per 1 WETH, 1e18 scale

        twap.update(); // snapshot at T0
        vm.warp(t0 + 20 minutes);
        _doubleWethPrice();
        twap.update(); // snapshot at T0+20m
        vm.warp(t0 + 30 minutes);

        (, uint256 twap30) = twap.twap30Min();
        (, uint256 twap10) = twap.twap10Min();
        (, uint256 spotNow) = twap.spot();

        assertEq(twap.snapshotCount(), 2);
        assertApproxEqRel(spotNow, startPrice * 2, 1e12); // 0.0001%
        assertApproxEqRel(twap30, startPrice * 4 / 3, 1e12);
        assertApproxEqRel(twap10, startPrice * 2, 1e12);

        emit log_named_decimal_uint("start price (DAI/WETH)", startPrice, 18);
        emit log_named_decimal_uint("spot now", spotNow, 18);
        emit log_named_decimal_uint("30-min TWAP", twap30, 18);
        emit log_named_decimal_uint("10-min TWAP", twap10, 18);
    }

    function test_Fork_TwapEqualsSpotWhenPriceIsFlat() public {
        twap.update();
        vm.warp(t0 + 30 minutes);

        (uint256 spot0, uint256 spot1) = twap.spot();
        (uint256 twap0, uint256 twap1) = twap.twap30Min();
        assertApproxEqRel(twap0, spot0, 1e12);
        assertApproxEqRel(twap1, spot1, 1e12);
    }

    function test_Fork_RevertWhen_NoSnapshotOldEnough() public {
        twap.update();
        vm.warp(t0 + 10 minutes);

        twap.twap10Min(); // 10 minutes of history: ok

        vm.expectRevert(UniswapV2Twap.NotEnoughHistory.selector);
        twap.twap30Min(); // only 10 minutes of history
    }
}
