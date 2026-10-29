// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockERC20} from "./utils/MockERC20.sol";
import {UniswapDeployer} from "./utils/UniswapDeployer.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3FlashCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {Test} from "forge-std/Test.sol";

contract UniswapV3Test is Test, UniswapDeployer, IUniswapV3FlashCallback {
    uint24 internal constant FEE = 3000;
    int24 internal constant MAX_TICK = 887_220;
    int24 internal constant MIN_TICK = -887_220;
    uint160 internal constant SQRT_PRICE_1_1 = 2 ** 96;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    address public alice = makeAddr("alice");

    function setUp() public {
        deployUniswap(address(this));

        MockERC20 a = new MockERC20("Token A", "TKA");
        MockERC20 b = new MockERC20("Token B", "TKB");

        (tokenA, tokenB) = address(a) < address(b) ? (a, b) : (b, a);
        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000 ether);

        tokenA.approve(address(positionManager), type(uint256).max);
        tokenB.approve(address(positionManager), type(uint256).max);

        tokenA.approve(address(v3Router), type(uint256).max);
        tokenB.approve(address(v3Router), type(uint256).max);
    }

    function _createPool() public returns (address pool) {
        return positionManager.createAndInitializePoolIfNecessary(address(tokenA), address(tokenB), FEE, SQRT_PRICE_1_1);
    }

    function _mint(int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1)
    {
        return positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(tokenA),
                token1: address(tokenB),
                fee: FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    function _mintFullRange(uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1)
    {
        return _mint(MIN_TICK, MAX_TICK, amount0, amount1);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, address to) internal returns (uint256) {
        return v3Router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: FEE,
                recipient: to,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function test_CreatePool() public {
        address pool = _createPool();
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        assertTrue(pool == v3Factory.getPool(address(tokenA), address(tokenB), FEE));
        (uint160 sqrtPriceX96, int24 tick,,,,,) = p.slot0();
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(tick, 0);
        assertEq(p.tickSpacing(), 60);
        assertEq(p.liquidity(), 0);
    }

    function test_Mint_FullRange() public {
        address pool = _createPool();
        IUniswapV3Pool p = IUniswapV3Pool(pool);

        uint256 balanceA = tokenA.balanceOf(address(this));
        uint256 balanceB = tokenB.balanceOf(address(this));

        (uint256 tokenId, uint128 liquidity, uint256 amountA, uint256 amountB) = _mintFullRange(100 ether, 100 ether);

        assertTrue(positionManager.ownerOf(tokenId) == address(this));
        assertTrue(positionManager.balanceOf(address(this)) == 1);

        (,,,,, int24 tickLower, int24 tickUpper, uint128 posLiquidity,,,,) = positionManager.positions(tokenId);
        assertEq(tickLower, MIN_TICK);
        assertEq(tickUpper, MAX_TICK);
        assertEq(posLiquidity, liquidity);

        assertEq(p.liquidity(), liquidity);

        assertEq(tokenA.balanceOf(pool), amountA);
        assertEq(tokenB.balanceOf(pool), amountB);
        assertEq(tokenA.balanceOf(address(this)), balanceA - amountA);
        assertEq(tokenB.balanceOf(address(this)), balanceB - amountB);

        assertApproxEqAbs(amountA, 100 ether, 1);
        assertApproxEqAbs(amountB, 100 ether, 1);
        assertApproxEqRel(liquidity, 100 ether, 1e12);
    }

    function test_Swap() public {
        address pool = _createPool();
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        (, uint128 liquidity,,) = _mintFullRange(100 ether, 100 ether);

        uint256 amountIn = 10 ether;
        tokenA.mint(alice, amountIn);

        uint256 poolA = tokenA.balanceOf(pool);
        uint256 poolB = tokenB.balanceOf(pool);

        (uint256 expectedOut,,,) = quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: address(tokenA), tokenOut: address(tokenB), amountIn: 10 ether, fee: FEE, sqrtPriceLimitX96: 0
            })
        );
        (uint160 sqrtBefore, int24 tickBefore,,,,,) = p.slot0();

        vm.startPrank(alice);
        tokenA.approve(address(v3Router), amountIn);
        uint256 amountOut = _swap(address(tokenA), address(tokenB), 10 ether, alice);
        vm.stopPrank();

        assertEq(amountOut, expectedOut);

        assertEq(tokenA.balanceOf(address(alice)), 0);
        assertEq(tokenB.balanceOf(address(alice)), amountOut);

        assertEq(tokenA.balanceOf(pool), poolA + amountIn);
        assertEq(tokenB.balanceOf(pool), poolB - amountOut);

        (uint160 sqrtAfter, int24 tickAfter,,,,,) = p.slot0();
        assertLt(sqrtAfter, sqrtBefore);
        assertLt(tickAfter, tickBefore);
        assertLt(tickAfter, 0);
        emit log_named_int("tick after", tickAfter);

        assertEq(p.liquidity(), liquidity);
        uint256 fee = amountIn * FEE / 1e6;
        assertApproxEqAbs(p.feeGrowthGlobal0X128(), fee * 2 ** 128 / liquidity, 2 ** 128 / liquidity + 1);
    }

    function test_Mint_NarrowRange() public {
        address pool = _createPool();
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        (, uint128 fullL, uint256 full0, uint256 full1) = _mintFullRange(100 ether, 100 ether);
        (, uint128 narrowL, uint256 narrowL0, uint256 narrowL1) = _mint(-600, 600, 100 ether, 100 ether);

        assertGt(narrowL, fullL);
        emit log_named_decimal_uint("fullL", fullL, 18);
        emit log_named_decimal_uint("narrowL", narrowL, 18);
        assertNotEq(narrowL, fullL);
        assertEq(p.liquidity(), fullL + narrowL);
    }

    function test_Mint_OutOfRange() public {
        address pool = _createPool();
        IUniswapV3Pool p = IUniswapV3Pool(pool);

        (, uint128 aboveL, uint256 above0, uint256 above1) = _mint(60, 600, 100 ether, 100 ether);
        assertEq(above1, 0);
        assertGt(above0, 0);

        (, uint128 belowL, uint256 below0, uint256 below1) = _mint(-600, -60, 100 ether, 100 ether);
        assertEq(below0, 0);
        assertGt(below1, 0);

        assertEq(p.liquidity(), 0);
    }

    function test_Swap_NarrowVsFullRange() public {
        _createPool();
        uint256 amountIn = 10 ether;

        uint256 snapshot = vm.snapshotState();

        _mintFullRange(100 ether, 100 ether);
        uint256 outFull = _swap(address(tokenA), address(tokenB), amountIn, address(this));

        vm.revertToState(snapshot);
        _mint(-600, 600, 100 ether, 100 ether);
        uint256 outNarrow = _swap(address(tokenA), address(tokenB), amountIn, address(this));

        emit log_named_decimal_uint("out full  ", outFull, 18);
        emit log_named_decimal_uint("out narrow", outNarrow, 18);
    }

    /// 풀에 유동성(토큰)은 있지만, 현재 가격에서 활성화된 유동성이 없어서 swap이 안 되는 경우
    function test_Swap_RevertsWhenNoActiveLiquidity() public {
        address pool = _createPool();
        IUniswapV3Pool p = IUniswapV3Pool(pool);

        // 현재 가격(tick 0)보다 위 범위 → token0만 들어감
        (, uint128 liquidity, uint256 used0, uint256 used1) = _mint(60, 600, 100 ether, 100 ether);

        // 유동성은 분명히 있음
        assertGt(liquidity, 0);
        assertEq(tokenA.balanceOf(pool), used0);
        assertEq(used1, 0);
        // 하지만 현재 tick이 범위 밖이라 활성 유동성은 0
        assertEq(p.liquidity(), 0);

        // token0 → token1: 가격이 내려가는 방향 = 범위에서 멀어지는 방향.
        // 풀에 token1이 하나도 없고 지나갈 유동성도 없어서 swap 결과가 (0, 0)이 되고,
        // SwapRouter의 callback이 require(amount0Delta > 0 || amount1Delta > 0)로 revert함 (메시지 없음)
        vm.expectRevert(bytes(""));
        _swap(address(tokenA), address(tokenB), 1 ether, address(this));

        // 반대 방향(token1 → token0)은 가격이 올라가 범위 안으로 들어가므로 성공
        uint256 out = _swap(address(tokenB), address(tokenA), 1 ether, address(this));
        assertGt(out, 0);
        (, int24 tick,,,,,) = p.slot0();
        assertGe(tick, 60);
        assertEq(p.liquidity(), liquidity);
    }

    struct Range {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    /// @dev 현재 tick을 포함하는 (lower <= tick < upper) 포지션들의 L 합 = 풀의 활성 유동성이어야 함
    function _activeLiquidity(Range[] memory ranges, int24 tick) internal pure returns (uint128 sum) {
        for (uint256 i; i < ranges.length; i++) {
            if (ranges[i].lower <= tick && tick < ranges[i].upper) sum += ranges[i].liquidity;
        }
    }

    function _logState(IUniswapV3Pool p, string memory label) internal {
        (, int24 tick,,,,,) = p.slot0();
        emit log_string(label);
        emit log_named_int("  tick", tick);
        emit log_named_decimal_uint("  liquidity", p.liquidity(), 18);
    }

    /// 겹치는 포지션 3개를 깔고, swap으로 tick을 움직이며 활성 유동성이 어떻게 바뀌는지 확인
    ///
    ///  L
    ///        ┌────────┐                       P2: -600 ~ 600
    ///        │   P2   │
    ///  ┌─────┤        │
    ///  │ P3  │        │                       P3: -1800 ~ -600 (token1만)
    ///  ├─────┴────────┴──────────────         P1: full range
    ///  │           P1
    ///  └─────┼────────┼───┼────▶ tick
    ///      -1800    -600  0   600
    function test_Swap_LiquidityDistributionAcrossTicks() public {
        address pool = _createPool();
        IUniswapV3Pool p = IUniswapV3Pool(pool);

        Range[] memory ranges = new Range[](3);
        (, uint128 l1,,) = _mintFullRange(100 ether, 100 ether);
        (, uint128 l2,,) = _mint(-600, 600, 100 ether, 100 ether);
        (, uint128 l3,,) = _mint(-1800, -600, 100 ether, 100 ether);

        ranges[0] = Range(MIN_TICK, MAX_TICK, l1);
        ranges[1] = Range(-600, 600, l2);
        ranges[2] = Range(-1800, -600, l3);

        // 경계 tick의 liquidityNet: 가격이 "올라가며" 그 tick을 넘을 때 L에 더해지는 값
        (, int128 net600,,,,,,) = p.ticks(600);
        (, int128 netM600,,,,,,) = p.ticks(-600);
        (, int128 netM1800,,,,,,) = p.ticks(-1800);

        assertEq(net600, -int128(l2)); // P2의 upper: 올라가며 넘으면 P2가 빠짐
        assertEq(netM600, int128(l2) - int128(l3)); // P2의 lower(+) 이면서 P3의 upper(-)
        assertEq(netM1800, int128(l3)); // P3의 lower

        // 시작: tick 0 → P1 + P2 활성
        _logState(p, "start");
        assertEq(p.liquidity(), l1 + l2);

        //tokenA(token0)를 조금씩 넣어 가격을 내림. 매 단계 활성 유동성 확인
        bool sawP1P2;
        bool sawP1P3;
        bool sawP1Only;
        for (uint256 i; i < 15; i++) {
            _swap(address(tokenA), address(tokenB), 25 ether, address(this));
            (, int24 tick,,,,,) = p.slot0();
            _logState(p, "after token0 -> token1 swap");
            assertEq(p.liquidity(), _activeLiquidity(ranges, tick));

            if (tick >= -600) sawP1P2 = true;
            else if (tick >= -1800) sawP1P3 = true;
            else sawP1Only = true;
        }
        // 세 구간을 모두 지나갔는지 확인
        assertTrue(sawP1P2);
        assertTrue(sawP1P3);
        assertTrue(sawP1Only);
        assertEq(p.liquidity(), l1); // -1800 아래에는 full range만 남음

        // 반대로 tokenB(token1)를 넣어 가격을 다시 올림: P3 → P2 순서로 다시 활성화
        for (uint256 i; i < 15; i++) {
            _swap(address(tokenB), address(tokenA), 25 ether, address(this));
            (, int24 tick,,,,,) = p.slot0();
            _logState(p, "after token1 -> token0 swap");
            assertEq(p.liquidity(), _activeLiquidity(ranges, tick));
        }
    }

    // ---------------------------------------------------------------------
    // flash loan
    // ---------------------------------------------------------------------

    enum Repay {
        Full, // 원금 + 수수료
        PrincipalOnly, // 원금만 (수수료 안 냄)
        Nothing // 안 갚음
    }

    struct FlashData {
        uint256 amount0;
        uint256 amount1;
        Repay repay;
    }

    address internal flashPool; // callback을 불러도 되는 풀 (보안 체크용)
    uint256 internal seenFee0; // callback이 받은 수수료 (assert용)
    uint256 internal seenBalance0; // callback 안에서 내가 가진 token0 (빌린 돈이 들어왔는지)
    uint256 internal seenPoolBalance0; // callback 안에서 풀이 가진 token0

    function _flash(IUniswapV3Pool p, uint256 amount0, Repay repay) internal {
        flashPool = address(p);
        p.flash(address(this), amount0, 0, abi.encode(FlashData(amount0, 0, repay)));
    }

    /// @dev pool.flash()가 토큰을 보낸 "직후" 호출됨. 여기서 빌린 돈을 쓰고, 끝나기 전에 갚아야 함.
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        // 아무나 이 함수를 부를 수 있으므로 진짜 풀인지 확인 (v2 uniswapV2Call 때와 같은 이유)
        require(msg.sender == flashPool, "not pool");
        FlashData memory d = abi.decode(data, (FlashData));

        seenFee0 = fee0;
        seenBalance0 = tokenA.balanceOf(address(this));
        seenPoolBalance0 = tokenA.balanceOf(msg.sender);

        // (여기서 빌린 돈으로 차익거래, 청산 등을 한다)

        if (d.repay == Repay.Full) {
            tokenA.transfer(msg.sender, d.amount0 + fee0);
            tokenB.transfer(msg.sender, d.amount1 + fee1);
        } else if (d.repay == Repay.PrincipalOnly) {
            tokenA.transfer(msg.sender, d.amount0);
            tokenB.transfer(msg.sender, d.amount1);
        }
    }

    function test_Flash() public {
        address pool = _createPool();
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        (, uint128 liquidity,,) = _mintFullRange(100 ether, 100 ether);

        uint256 amount = 50 ether;
        uint256 poolBefore = tokenA.balanceOf(pool);
        uint256 myBefore = tokenA.balanceOf(address(this));

        _flash(p, amount, Repay.Full);

        // 수수료 = amount × fee tier (0.3%), 올림
        uint256 expectedFee = amount * FEE / 1e6;
        assertEq(seenFee0, expectedFee);

        // callback 안: 빌린 돈이 내 지갑에 있었고, 풀에서는 빠져 있었음
        assertEq(seenBalance0, myBefore + amount);
        assertEq(seenPoolBalance0, poolBefore - amount);

        // 끝난 뒤: 풀은 수수료만큼 늘고, 나는 수수료만큼 줄어듦
        assertEq(tokenA.balanceOf(pool), poolBefore + expectedFee);
        assertEq(tokenA.balanceOf(address(this)), myBefore - expectedFee);

        // flash 수수료도 swap 수수료처럼 활성 LP에게 분배됨
        assertEq(p.feeGrowthGlobal0X128(), expectedFee * 2 ** 128 / liquidity);
        // 가격과 유동성은 그대로 (flash는 swap이 아님)
        (uint160 sqrtPriceX96,,,,,,) = p.slot0();
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(p.liquidity(), liquidity);
    }

    function test_Flash_RevertsWithoutFee() public {
        IUniswapV3Pool p = IUniswapV3Pool(_createPool());
        _mintFullRange(100 ether, 100 ether);

        // 원금은 갚았지만 수수료가 모자람 → balance0Before + fee0 > balance0After
        vm.expectRevert(bytes("F0"));
        _flash(p, 50 ether, Repay.PrincipalOnly);
    }

    function test_Flash_RevertsWithoutRepay() public {
        IUniswapV3Pool p = IUniswapV3Pool(_createPool());
        _mintFullRange(100 ether, 100 ether);
        uint256 myBefore = tokenA.balanceOf(address(this));

        // 안 갚으면 트랜잭션 전체가 revert → 빌린 적이 없던 것처럼 됨
        vm.expectRevert(bytes("F0"));
        _flash(p, 50 ether, Repay.Nothing);
        assertEq(tokenA.balanceOf(address(this)), myBefore);
    }

    function test_Flash_RevertsWhenBorrowingMoreThanPool() public {
        IUniswapV3Pool p = IUniswapV3Pool(_createPool());
        _mintFullRange(100 ether, 100 ether);

        // 풀에 있는 것보다 많이 빌릴 수는 없음 (토큰 전송 실패)
        vm.expectRevert(bytes("TF"));
        _flash(p, 101 ether, Repay.Full);
    }

    function test_Flash_RevertsWithoutActiveLiquidity() public {
        IUniswapV3Pool p = IUniswapV3Pool(_createPool());
        // 현재 가격 밖 범위 → 토큰은 있지만 활성 유동성 0 → 수수료를 받을 LP가 없음
        _mint(60, 600, 100 ether, 100 ether);

        vm.expectRevert(bytes("L"));
        _flash(p, 1 ether, Repay.Full);
    }

    function test_FlashCallback_RevertsFromFakePool() public {
        // 진짜 풀이 아닌 누군가가 callback을 직접 부르면 거부
        vm.prank(alice);
        vm.expectRevert(bytes("not pool"));
        this.uniswapV3FlashCallback(0, 0, abi.encode(FlashData(0, 0, Repay.Nothing)));
    }
}
