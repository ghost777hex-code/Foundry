// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {
    IUniswapV3Pool
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IOracle} from "../src/IOracle.sol";
import {V3Router} from "../src/V3Router.sol";

interface IWETH {
    function deposit() external payable;
}

contract V3ForkTest is Test {
    IUniswapV3Pool constant pool =
        IUniswapV3Pool(0x701B319AFF36311F720f0a1ebD6636Dd84Bb3E8B);
    IOracle constant oracle =
        IOracle(0x17881b9B731c78a546E5ab9dED28798b7C68CFA7);
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    uint256 constant ETH_USD = 2200; // 1ETH = 2200$

    address token0;
    address token1;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        token0 = pool.token0();
        token1 = pool.token1();
        require(token1 == WETH, "token1 is not WETH");

        vm.deal(address(this), 1_000_000_000_000 ether);
        IWETH(WETH).deposit{value: 1_000_000_000_000 ether}();
    }

    function test_Hello1() public {
        uint160 oracleBefore = oracle.getV3SqrtPrice(
            address(pool),
            180 seconds,
            1800 seconds
        );
        console.log("oracle before (sqrtPriceX96):", oracleBefore);

        uint256 snap = vm.snapshotState();

        // 1800 초안에 TWAP을 3배로 만들기
        console.log("---------- 1800 seconds ----------");
        uint160 sqrtPriceLimitX96 = oracleBefore * 3;
        // WETH(token1)를 팔아서 token0 가격을 올린다
        (, int256 amount1) = pool.swap(
            address(this),
            false,
            int256(IERC20(WETH).balanceOf(address(this))),
            sqrtPriceLimitX96,
            ""
        );
        (uint160 spotAfter, int24 tickAfter, , , , , ) = pool.slot0();
        console.log("spot after (sqrtPriceX96):", spotAfter);
        console.log("tick after:", int256(tickAfter));

        vm.warp(block.timestamp + 1800);

        uint160 oracleAfter = oracle.getV3SqrtPrice(
            address(pool),
            180 seconds,
            1800 seconds
        );
        console.log("oracle after 1800s (sqrtPriceX96):", oracleAfter);
        console.log(
            "oracle after / before",
            (uint256(oracleAfter) * 1e18) / oracleBefore
        );
        console.log("spent ETH:", uint256(amount1) / 1e18);
        console.log("spent USD", (uint256(amount1) * ETH_USD) / 1e18);

        vm.revertToState(snap);

        // 180 초안에 TWAP을 3배로 만들기
        console.log("---------- 180 seconds ----------");
        console.log("oracle before (sqrtPriceX96):", oracleBefore);
        sqrtPriceLimitX96 = oracleBefore * 3 ** 10;
        console.log("target (sqrtPriceX96):", sqrtPriceLimitX96);
        (, amount1) = pool.swap(
            address(this),
            false,
            int256(IERC20(WETH).balanceOf(address(this))),
            sqrtPriceLimitX96,
            ""
        );

        vm.warp(block.timestamp + 180);

        oracleAfter = oracle.getV3SqrtPrice(
            address(pool),
            180 seconds,
            1800 seconds
        );
        console.log("oracle after 180s (sqrtPriceX96):", oracleAfter);
        console.log(
            "oracle after / before",
            (uint256(oracleAfter) * 1e18) / oracleBefore
        );
        console.log("spent ETH:", uint256(amount1) / 1e18);
        console.log("spent USD", (uint256(amount1) * ETH_USD) / 1e18);
    }

    function test_Hello2() public {
        uint160 oracleBefore = oracle.getV3SqrtPrice(
            address(pool),
            180 seconds,
            1800 seconds
        );
        (uint160 spotBefore, , , , , , ) = pool.slot0();
        console.log("oracle before (sqrtPriceX96):", oracleBefore);
        console.log("spot before (sqrtPriceX96):", spotBefore);

        address bot = makeAddr("bot");
        V3Router router = new V3Router(FACTORY);
        deal(token0, bot, 1_000_000_000_000e18);
        vm.prank(bot);
        IERC20(token0).approve(address(router), type(uint256).max);

        uint160 sqrtPriceLimitX96 = spotBefore * 15;
        uint256 spent;

        // 첫 블록
        (, int256 amount1) = pool.swap(
            address(this),
            false,
            int256(IERC20(WETH).balanceOf(address(this))),
            sqrtPriceLimitX96,
            ""
        );
        spent += uint256(amount1);

        uint256 blocks = 0;
        while (true) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            blocks++;

            if (blocks % 2 == 1) {
                // Bot 블록
                vm.startPrank(bot);
                uint256 beforeBalance = IERC20(token0).balanceOf(bot);
                router.swap(
                    address(pool),
                    true,
                    int256(IERC20(token0).balanceOf(bot)),
                    spotBefore
                );
                uint256 afterBalance = IERC20(token0).balanceOf(bot);

                console.log("Bot spent token0:", beforeBalance - afterBalance);
                (uint160 spotCurrent, int24 tickCurrent, , , , , ) = pool.slot0();
                console.log("Spot Current after bot swap:", spotCurrent);
                console.log("Tick Current after bot swap:", tickCurrent);

                vm.stopPrank();
            } else {
                // 내 블록

                uint256 beforeBalance = IERC20(WETH).balanceOf(address(this));

                (, amount1) = pool.swap(
                    address(this),
                    false,
                    int256(IERC20(WETH).balanceOf(address(this))),
                    sqrtPriceLimitX96,
                    ""
                );

                uint256 afterBalance = IERC20(WETH).balanceOf(address(this));
                console.log("My spent WETH:", beforeBalance - afterBalance);
                (uint160 spotCurrent, int24 tickCurrent, , , , , ) = pool.slot0();
                console.log("Spot Current before bot swap:", spotCurrent);
                console.log("Tick Current before bot swap:", tickCurrent);
                spent += uint256(amount1);

                uint256 ratio = (uint256(
                    oracle.getV3SqrtPrice(
                        address(pool),
                        180 seconds,
                        1800 seconds
                    )
                ) * 1e18) / oracleBefore;
                if (ratio >= 2.999e18) break;
            }
        }

        console.log("blocks:", blocks);
        console.log("seconds:", blocks * 12);
        console.log("spent ETH:", spent / 1e18);
        console.log("spent USD", (spent * ETH_USD) / 1e18);
        uint160 oracleAfter = oracle.getV3SqrtPrice(
            address(pool),
            180 seconds,
            1800 seconds
        );
        console.log("oracle after", oracleAfter);
        console.log(
            "oracle after / before",
            (uint256(oracleAfter) * 1e18) / oracleBefore
        );
    }

    // pool 의 유동성 분포: 초기화된 tick 들을 왼쪽(낮은 가격)부터 훑으며 liquidityNet 을 누적한다
    // L(구간 [tick, 다음 tick)) = 그 tick 까지의 liquidityNet 합
    function test_Liquidity() public view {
        int24 spacing = pool.tickSpacing();
        (, int24 currentTick, , , , , ) = pool.slot0();
        console.log("fee:", pool.fee());
        console.log("tickSpacing:", int256(spacing));
        console.log("current tick:", int256(currentTick));
        console.log("pool.liquidity():", pool.liquidity());

        // full-range = [spacing 에 맞춘 MIN tick, MAX tick] 포지션 (v2 와 같은 범위)
        int24 minUsable = (int24(-887272) / spacing) * spacing; // 0 쪽으로 잘림 -> MIN 안쪽
        int24 maxUsable = (int24(887272) / spacing) * spacing;
        (uint128 grossMin, int128 netMin, , , , , , ) = pool.ticks(minUsable);
        (uint128 grossMax, int128 netMax, , , , , , ) = pool.ticks(maxUsable);
        console.log("min usable tick:", int256(minUsable));
        console.log("  liquidityGross:", grossMin);
        console.log("  liquidityNet:", int256(netMin));
        console.log("max usable tick:", int256(maxUsable));
        console.log("  liquidityGross:", grossMax);
        console.log("  liquidityNet:", int256(netMax));
        // 두 tick 모두 쓰이고 있으면 full-range 포지션이 있다 (양은 대략 min(netMin, -netMax))
        console.log("has full-range:", grossMin > 0 && grossMax > 0);

        // tickBitmap: word(int16) 하나에 256개의 (tick / spacing) 비트
        int16 minWord = int16((int24(-887272) / spacing) >> 8);
        int16 maxWord = int16((int24(887272) / spacing) >> 8);

        int256 L; // 현재 구간의 유동성
        for (int16 w = minWord; w <= maxWord; w++) {
            uint256 bitmap = pool.tickBitmap(w);
            if (bitmap == 0) continue;
            for (uint256 b = 0; b < 256; b++) {
                if (bitmap & (1 << b) == 0) continue;
                int24 tick = (int24(w) * 256 + int24(uint24(b))) * spacing;
                (, int128 liquidityNet, , , , , , ) = pool.ticks(tick);
                L += liquidityNet; // 왼쪽 -> 오른쪽으로 tick 을 넘을 때 L += liquidityNet
                console.log(
                    string.concat(
                        "tick ", vm.toString(int256(tick)),
                        "  net ", vm.toString(int256(liquidityNet)),
                        "  L from here ", vm.toString(L)
                    )
                );
            }
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata
    ) external {
        require(msg.sender == address(pool), "not pool");
        if (amount0Delta > 0)
            IERC20(token0).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0)
            IERC20(token1).transfer(msg.sender, uint256(amount1Delta));
    }
}
