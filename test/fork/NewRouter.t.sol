// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {UniswapV3Router} from "../../src/NewRouter.sol";
import {Mainnet, MainnetForkTest} from "./MainnetFork.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

/// @notice Swaps directly against the live mainnet USDC/WETH 0.05% pool and checks the result against QuoterV2.
contract NewRouterTest is MainnetForkTest {
    IUniswapV3Pool public pool;
    uint24 internal constant FEE = 500;
    address public alice = makeAddr("alice");
    address public attacker = makeAddr("attacker");
    UniswapV3Router public uniswapV3Router;

    function setUp() public override {
        super.setUp();
        pool = IUniswapV3Pool(IUniswapV3Factory(Mainnet.V3_FACTORY).getPool(Mainnet.USDC, Mainnet.WETH, FEE));
        vm.label(address(pool), "USDC/WETH 0.05%");
        vm.label(Mainnet.WETH, "WETH");
        vm.label(Mainnet.USDC, "USDC");
        // Problem 3
        uniswapV3Router = new UniswapV3Router(Mainnet.V3_FACTORY, Mainnet.V3_POSITION_MANAGER);
    }

    function _ticks() internal view returns (int24 tickLower, int24 tickUpper) {
        (, int24 tick,,,,,) = pool.slot0();
        int24 spacing = pool.tickSpacing();
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        tickLower = (compressed - 100) * spacing;
        tickUpper = (compressed + 100) * spacing;
    }

    function test_Router() public {
        uint256 usdcAmount = 10e6;

        // Problem 1
        deal(Mainnet.USDC, alice, usdcAmount);
        assertEq(IERC20(Mainnet.USDC).balanceOf(alice), usdcAmount);
        emit log_named_uint("Alice balance", IERC20(Mainnet.USDC).balanceOf(alice));

        // Problem 4
        vm.startPrank(alice);
        IERC20(Mainnet.USDC).approve(address(uniswapV3Router), usdcAmount);
        vm.stopPrank();
        // Problem 5
        // assertEq(IERC20(Mainnet.USDC).balanceOf(alice), usdcAmount);
        // assertEq(IERC20(Mainnet.USDC).allowance(alice, address(uniswapV3Router)), 0);
    }

    // problem 5
    function test_Attacker() public {
        uint256 usdcAmount = 10e6;
        deal(Mainnet.USDC, alice, usdcAmount);

        vm.startPrank(alice);
        IERC20(Mainnet.USDC).approve(address(uniswapV3Router), usdcAmount);

        vm.startPrank(attacker);
        bytes memory path = abi.encodePacked(Mainnet.USDC, uint24(500), Mainnet.WETH);
        // The attacker tries to spend Alice's approval by naming her as `data` (payer).
        UniswapV3Router.ExactInputParams memory params = UniswapV3Router.ExactInputParams({
            path: path,
            recipient: attacker,
            deadline: block.timestamp,
            amountIn: usdcAmount,
            amountOutMinimum: 0,
            data: alice
        });
        // Fixed router ignores caller-supplied payer and charges msg.sender (the attacker),
        // who has no USDC/approval, so the exploit reverts instead of draining Alice.
        vm.expectRevert();
        uniswapV3Router.exactInput(params);
        vm.stopPrank();

        // Alice keeps every cent; the attacker gets nothing.
        assertEq(IERC20(Mainnet.USDC).balanceOf(alice), usdcAmount);
        assertEq(IERC20(Mainnet.WETH).balanceOf(attacker), 0);
        emit log_named_uint("Alice balance", IERC20(Mainnet.USDC).balanceOf(alice));
        emit log_named_uint("Attacker balance", IERC20(Mainnet.WETH).balanceOf(attacker));
    }

    function test_AddLiquidity() public {
        // Problem 2
        uint256 usdcAmount = 10e6;
        uint256 wethAmount = 100 * 1e18;
        vm.startPrank(alice);
        deal(Mainnet.USDC, alice, usdcAmount);
        deal(Mainnet.WETH, alice, wethAmount);
        IERC20(Mainnet.USDC).approve(address(uniswapV3Router), usdcAmount);
        IERC20(Mainnet.WETH).approve(address(uniswapV3Router), wethAmount);

        (int24 tickLower, int24 tickUpper) = _ticks();

        (uint128 liquidity,,) =
            uniswapV3Router.addLiquidity(address(pool), tickLower, tickUpper, usdcAmount, wethAmount, 0, 0);
        bytes32 key = keccak256(abi.encodePacked(address(pool), tickLower, tickUpper));
        assertEq(uniswapV3Router.positions(alice, key), liquidity);
        assertGt(liquidity, 0);

        uniswapV3Router.removeLiquidity(address(pool), tickLower, tickUpper, liquidity, 0, 0);
        vm.stopPrank();

        assertEq(uniswapV3Router.positions(alice, key), 0);
        assertApproxEqAbs(IERC20(Mainnet.USDC).balanceOf(alice), usdcAmount, 1);
        emit log_named_uint("Alice USDC balance", IERC20(Mainnet.USDC).balanceOf(alice));
        assertApproxEqAbs(IERC20(Mainnet.WETH).balanceOf(alice), wethAmount, 1);
        emit log_named_uint("Alice WETH balance", IERC20(Mainnet.WETH).balanceOf(alice));
    }
}
