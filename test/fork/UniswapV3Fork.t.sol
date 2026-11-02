// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Mainnet, MainnetForkTest} from "./MainnetFork.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3FlashCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

/// @notice Swaps directly against the live mainnet USDC/WETH 0.05% pool and checks the result against QuoterV2.
contract UniswapV3ForkTest is MainnetForkTest, IUniswapV3SwapCallback, IUniswapV3FlashCallback {
    uint24 internal constant FEE = 500;
    // TickMath.MIN_SQRT_RATIO + 1 / MAX_SQRT_RATIO - 1: "no price limit" for each direction.
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    // TickMath.MIN_TICK / MAX_TICK
    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;

    uint256 internal constant MINT_USDC = 10_000e6;
    uint256 internal constant MINT_WETH = 10 ether;

    IQuoterV2 internal constant QUOTER = IQuoterV2(Mainnet.V3_QUOTER_V2);
    INonfungiblePositionManager internal constant POSITION_MANAGER =
        INonfungiblePositionManager(Mainnet.V3_POSITION_MANAGER);

    IUniswapV3Pool public pool;

    function setUp() public override {
        super.setUp();
        pool = IUniswapV3Pool(IUniswapV3Factory(Mainnet.V3_FACTORY).getPool(Mainnet.USDC, Mainnet.WETH, FEE));
        vm.label(address(pool), "USDC/WETH 0.05%");
        vm.label(address(QUOTER), "QuoterV2");
        vm.label(address(POSITION_MANAGER), "NonfungiblePositionManager");
        vm.label(Mainnet.WETH, "WETH");
        vm.label(Mainnet.USDC, "USDC");
    }

    function _quote(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        // QuoterV2 is not view: it runs the swap and reverts with the result. Fine to call from a test.
        (amountOut,,,) = QUOTER.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: FEE, sqrtPriceLimitX96: 0
            })
        );
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        bool zeroForOne = tokenIn < tokenOut;
        (int256 amount0, int256 amount1) = pool.swap(
            address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT, ""
        );
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    function _mint(int24 tickLower, int24 tickUpper, uint256 usdcDesired, uint256 wethDesired)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 usdcUsed, uint256 wethUsed)
    {
        deal(Mainnet.WETH, address(this), wethDesired);
        deal(Mainnet.USDC, address(this), usdcDesired);
        IERC20(Mainnet.WETH).approve(address(POSITION_MANAGER), wethDesired);
        IERC20(Mainnet.USDC).approve(address(POSITION_MANAGER), usdcDesired);

        return POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(Mainnet.USDC),
                token1: address(Mainnet.WETH),
                fee: FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: usdcDesired,
                amount1Desired: wethDesired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    /// @dev Amounts are in token0/token1 order everywhere: USDC first, then WETH.
    function _mintFullRange(uint256 usdcDesired, uint256 wethDesired)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 usdcUsed, uint256 wethUsed)
    {
        int24 spacing = pool.tickSpacing();
        return _mint((MIN_TICK / spacing) * spacing, (MAX_TICK / spacing) * spacing, usdcDesired, wethDesired);
    }

    struct Range {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    /// @dev Far more USDC than any swap below needs (1 trillion). The price limit stops the swap,
    /// so the pool only takes what it needs to reach the target tick.
    uint256 internal constant SWAP_BUDGET = 1e12 * 1e6;

    /// @dev Current tick rounded to the tick spacing; the fork version of "tick 0".
    function _centerTick() internal view returns (int24) {
        (, int24 tick,,,,,) = pool.slot0();
        int24 spacing = pool.tickSpacing();
        return (tick / spacing) * spacing;
    }

    /// @dev Sells USDC (token0) until the price is exactly at `target` (price goes down = tick goes down).
    function _swapDownToTick(int24 target) internal {
        deal(Mainnet.USDC, address(this), SWAP_BUDGET);
        pool.swap(address(this), true, int256(SWAP_BUDGET), TickMath.getSqrtRatioAtTick(target), "");
        (, int24 tick,,,,,) = pool.slot0();
        assertEq(tick, target, "swap did not reach the target tick");
    }

    function _liquidityNet(int24 tick) internal view returns (int128 net) {
        (, net,,,,,,) = pool.ticks(tick);
    }

    function _activeLiquidity(Range[] memory ranges, int24 tick) internal pure returns (uint128 sum) {
        for (uint256 i; i < ranges.length; i++) {
            if (ranges[i].lower <= tick && tick < ranges[i].upper) sum += ranges[i].liquidity;
        }
    }

    /// @dev Other LPs' active liquidity at each target, measured on a copy of the state without our
    /// positions and then thrown away with revertToState.
    function _othersLiquidityAt(int24[3] memory targets) internal returns (uint128[3] memory others) {
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 3; i++) {
            _swapDownToTick(targets[i]);
            others[i] = pool.liquidity();
        }
        vm.revertToState(snapshot);
    }

    /// @dev P1 full range, P2 = center ± 600, P3 = center - 1800 ~ center - 600 (below the price: WETH only).
    function _mintRanges(int24 c) internal returns (Range[] memory ranges) {
        int24 spacing = pool.tickSpacing();
        ranges = new Range[](3);
        (, uint128 l1,,) = _mintFullRange(MINT_USDC, MINT_WETH);
        (, uint128 l2,,) = _mint(c - 600, c + 600, MINT_USDC, MINT_WETH);
        (, uint128 l3,,) = _mint(c - 1800, c - 600, MINT_USDC, MINT_WETH);
        ranges[0] = Range((MIN_TICK / spacing) * spacing, (MAX_TICK / spacing) * spacing, l1);
        ranges[1] = Range(c - 600, c + 600, l2);
        ranges[2] = Range(c - 1800, c - 600, l3);
    }

    function _logState(string memory label, uint128 others) internal {
        (, int24 tick,,,,,) = pool.slot0();
        emit log_string(label);
        emit log_named_int("  tick", tick);
        emit log_named_decimal_uint("  pool liquidity", pool.liquidity(), 18);
        emit log_named_decimal_uint("  ours", pool.liquidity() - others, 18);
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        if (msg.sender != address(pool)) revert();
        if (amount0Delta > 0) IERC20(pool.token0()).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(pool.token1()).transfer(msg.sender, uint256(amount1Delta));
    }

    function test_Fork_PoolExists() public view {
        assertTrue(address(pool) != address(0));
        assertEq(pool.token0(), Mainnet.USDC);
        assertEq(pool.token1(), Mainnet.WETH);
        assertGt(pool.liquidity(), 0);
    }

    function test_Fork_SwapWethForUsdc_MatchesQuoter() public {
        uint256 amountIn = 1 ether;
        uint256 quoted = _quote(Mainnet.WETH, Mainnet.USDC, amountIn);
        deal(Mainnet.WETH, address(this), amountIn);
        uint256 usdcBefore = IERC20(Mainnet.USDC).balanceOf((address(this)));

        uint256 amountOut = _swap(Mainnet.WETH, Mainnet.USDC, amountIn);
        assertEq(amountOut, quoted);
        assertEq(IERC20(Mainnet.WETH).balanceOf(address(this)), 0);
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(this)) - usdcBefore, amountOut);
        emit log_named_decimal_uint("USDC for 1 WETH", amountOut, 6);
    }

    function test_Fork_Callback_RevertsForNonPool() public {
        vm.expectRevert();
        this.uniswapV3SwapCallback(1, 0, "");
    }

    function test_Fork_FullRange() public {
        uint256 poolWethBefore = IERC20(Mainnet.WETH).balanceOf(address(pool));
        uint256 poolUsdcBefore = IERC20(Mainnet.USDC).balanceOf(address(pool));
        uint128 poolLiquidityBefore = pool.liquidity();
        uint256 nftsBefore = POSITION_MANAGER.balanceOf(address(this));

        (uint256 tokenId, uint128 liquidity, uint256 usdcUsed, uint256 wethUsed) = _mintFullRange(MINT_USDC, MINT_WETH);
        assertEq(POSITION_MANAGER.ownerOf(tokenId), address(this));
        assertEq(POSITION_MANAGER.balanceOf(address(this)), nftsBefore + 1);

        {
            int24 spacing = pool.tickSpacing();
            (,,,,, int24 tickLower, int24 tickUpper, uint128 posLiquidity,,,,) = POSITION_MANAGER.positions(tokenId);
            assertEq(tickLower, (MIN_TICK / spacing) * spacing);
            assertEq(tickUpper, (MAX_TICK / spacing) * spacing);
            assertEq(posLiquidity, liquidity);
        }

        assertEq(pool.liquidity(), poolLiquidityBefore + liquidity);

        assertEq(IERC20(Mainnet.USDC).balanceOf(address(pool)), poolUsdcBefore + usdcUsed);
        assertEq(IERC20(Mainnet.WETH).balanceOf(address(pool)), poolWethBefore + wethUsed);
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(this)), MINT_USDC - usdcUsed);
        assertEq(IERC20(Mainnet.WETH).balanceOf(address(this)), MINT_WETH - wethUsed);

        emit log_named_decimal_uint("USDC used", usdcUsed, 6);
        emit log_named_decimal_uint("WETH used", wethUsed, 18);
    }

    function test_Fork_Mint_NarrowRange() public {
        (, int24 tick,,,,,) = pool.slot0();
        int24 spacing = pool.tickSpacing();
        int24 center = (tick / spacing) * spacing;
        uint128 poolLiquidityBefore = pool.liquidity();

        (, uint128 fullL,,) = _mintFullRange(MINT_USDC, MINT_WETH);
        // ±600 ticks ≈ ±3% around the current price.
        (, uint128 narrowL,,) = _mint(center - 300, center + 300, MINT_USDC, MINT_WETH);

        assertGt(narrowL, fullL);
        emit log_named_decimal_uint("fullL", fullL, 18);
        emit log_named_decimal_uint("narrowL", narrowL, 18);
        assertEq(pool.liquidity(), poolLiquidityBefore + fullL + narrowL);
    }

    /// Fork version of UniswapV3Test.test_Swap_LiquidityDistributionAcrossTicks, with c = current tick:
    ///
    ///  L (ours)
    ///        ┌────────┐                       P2: c-600 ~ c+600
    ///        │   P2   │
    ///  ┌─────┤        │
    ///  │ P3  │        │                       P3: c-1800 ~ c-600 (token1 = WETH only)
    ///  ├─────┴────────┴──────────────         P1: full range
    ///  │           P1
    ///  └─────┼────────┼───┼────▶ tick
    ///     c-1800    c-600 c  c+600
    ///
    /// The live pool also holds other LPs' positions, and their liquidity changes from tick to tick.
    /// So their part is measured first at each target tick (without our positions), and only the
    /// difference is compared with our ranges.
    function test_Fork_Swap_LiquidityDistributionAcrossTicks() public {
        int24 c = _centerTick();
        // One target inside each region. Not multiples of 10, so never on a position boundary.
        int24[3] memory targets = [c - 305, c - 1205, c - 2405];
        uint128[3] memory others = _othersLiquidityAt(targets);

        int128[3] memory netBefore = [_liquidityNet(c + 600), _liquidityNet(c - 600), _liquidityNet(c - 1800)];
        uint128 othersStart = pool.liquidity();

        Range[] memory ranges = _mintRanges(c);
        uint128 l1 = ranges[0].liquidity;
        uint128 l2 = ranges[1].liquidity;
        uint128 l3 = ranges[2].liquidity;

        // liquidityNet: what is added to L when the price crosses the tick going up. Other LPs may
        // share these ticks, so compare the change.
        assertEq(_liquidityNet(c + 600) - netBefore[0], -int128(l2)); // P2 upper
        assertEq(_liquidityNet(c - 600) - netBefore[1], int128(l2) - int128(l3)); // P2 lower (+), P3 upper (-)
        assertEq(_liquidityNet(c - 1800) - netBefore[2], int128(l3)); // P3 lower

        // Start: current tick is inside P1 and P2.
        _logState("start", othersStart);
        assertEq(pool.liquidity() - othersStart, l1 + l2);

        // Sell USDC to push the price down through P2 -> P3 -> P1 only.
        for (uint256 i; i < 3; i++) {
            _swapDownToTick(targets[i]);
            _logState("after USDC -> WETH swap", others[i]);
            assertEq(pool.liquidity() - others[i], _activeLiquidity(ranges, targets[i]));
        }
        assertEq(pool.liquidity() - others[2], l1); // below c-1800 only the full range is ours
    }

    // ---------------------------------------------------------------------
    // flash loan (fork version of the UniswapV3Test flash tests, on the live USDC/WETH 0.05% pool)
    // ---------------------------------------------------------------------

    enum Repay {
        Full, // principal + fee
        PrincipalOnly, // no fee
        Nothing
    }

    struct FlashData {
        uint256 amount0;
        uint256 amount1;
        Repay repay;
    }

    uint256 internal seenFee0; // fees the pool asked for in the callback
    uint256 internal seenFee1;
    uint256 internal seenBalance0; // our USDC inside the callback (did the loan arrive?)
    uint256 internal seenPoolBalance0; // pool's USDC inside the callback

    /// @dev Borrows USDC (token0) and/or WETH (token1) from the live pool.
    function _flash(uint256 usdcAmount, uint256 wethAmount, Repay repay) internal {
        pool.flash(address(this), usdcAmount, wethAmount, abi.encode(FlashData(usdcAmount, wethAmount, repay)));
    }

    /// @dev Flash fee = amount × fee tier (0.05%), rounded up like FullMath.mulDivRoundingUp in the pool.
    function _flashFee(uint256 amount) internal pure returns (uint256) {
        return Math.mulDiv(amount, FEE, 1e6, Math.Rounding.Up);
    }

    /// @dev Called by pool.flash() right after it sent the tokens. Use them here and repay before returning.
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        // Anyone can call this, so make sure it is the real pool.
        require(msg.sender == address(pool), "not pool");
        FlashData memory d = abi.decode(data, (FlashData));

        seenFee0 = fee0;
        seenFee1 = fee1;
        seenBalance0 = IERC20(Mainnet.USDC).balanceOf(address(this));
        seenPoolBalance0 = IERC20(Mainnet.USDC).balanceOf(msg.sender);

        // (arbitrage, liquidations, ... would happen here)

        if (d.repay == Repay.Full) {
            IERC20(Mainnet.USDC).transfer(msg.sender, d.amount0 + fee0);
            IERC20(Mainnet.WETH).transfer(msg.sender, d.amount1 + fee1);
        } else if (d.repay == Repay.PrincipalOnly) {
            IERC20(Mainnet.USDC).transfer(msg.sender, d.amount0);
            IERC20(Mainnet.WETH).transfer(msg.sender, d.amount1);
        }
    }

    function test_Fork_Flash() public {
        uint256 amount = 1_000_000e6; // 1M USDC, we hold none of it
        uint256 fee = _flashFee(amount); // 500 USDC
        // We only have to bring the fee; the principal comes from the pool.
        deal(Mainnet.USDC, address(this), fee);
        uint256 poolBefore = IERC20(Mainnet.USDC).balanceOf(address(pool));

        _flash(amount, 0, Repay.Full);

        assertEq(seenFee0, fee);
        assertEq(seenFee1, 0);
        // Inside the callback: the loan was in our wallet and missing from the pool.
        assertEq(seenBalance0, fee + amount);
        assertEq(seenPoolBalance0, poolBefore - amount);
        // After: the pool is up by the fee, we are down by the fee.
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(pool)), poolBefore + fee);
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(this)), 0);
        emit log_named_decimal_uint("fee for 1M USDC", fee, 6);
    }

    function test_Fork_Flash_FeeSplitBetweenLPsAndProtocol() public {
        uint256 amount = 1_000_000e6;
        uint256 fee = _flashFee(amount);
        deal(Mainnet.USDC, address(this), fee);

        (uint160 sqrtPriceBefore,,,,, uint8 feeProtocol,) = pool.slot0();
        uint128 liquidity = pool.liquidity();
        uint256 growthBefore = pool.feeGrowthGlobal0X128();
        (uint128 protocolBefore,) = pool.protocolFees();

        _flash(amount, 0, Repay.Full);

        // Fee switch: the low 4 bits of feeProtocol are token0's setting. N != 0 means 1/N of the fee
        // goes to the protocol (mainnet has it on: 68 = 0x44 → 1/4 for both tokens).
        uint8 feeProtocol0 = feeProtocol % 16;
        uint256 protocolCut = feeProtocol0 == 0 ? 0 : fee / feeProtocol0;
        (uint128 protocolAfter,) = pool.protocolFees();
        assertEq(protocolAfter - protocolBefore, protocolCut);

        // The rest is shared by the LPs that are active right now, per unit of liquidity.
        assertEq(pool.feeGrowthGlobal0X128() - growthBefore, Math.mulDiv(fee - protocolCut, 2 ** 128, liquidity));

        // A flash loan is not a swap: price and liquidity do not move.
        (uint160 sqrtPriceAfter,,,,,,) = pool.slot0();
        assertEq(sqrtPriceAfter, sqrtPriceBefore);
        assertEq(pool.liquidity(), liquidity);
        emit log_named_decimal_uint("protocol cut (USDC)", protocolCut, 6);
    }

    function test_Fork_Flash_BothTokens() public {
        uint256 usdcAmount = 1_000_000e6;
        uint256 wethAmount = 500 ether;
        uint256 fee0 = _flashFee(usdcAmount);
        uint256 fee1 = _flashFee(wethAmount);
        // deal() overwrites, so the WETH this mainnet address already holds is replaced by exactly the fee.
        deal(Mainnet.USDC, address(this), fee0);
        deal(Mainnet.WETH, address(this), fee1);
        uint256 poolUsdcBefore = IERC20(Mainnet.USDC).balanceOf(address(pool));
        uint256 poolWethBefore = IERC20(Mainnet.WETH).balanceOf(address(pool));

        _flash(usdcAmount, wethAmount, Repay.Full);

        assertEq(seenFee0, fee0);
        assertEq(seenFee1, fee1);
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(pool)), poolUsdcBefore + fee0);
        assertEq(IERC20(Mainnet.WETH).balanceOf(address(pool)), poolWethBefore + fee1);
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(this)), 0);
        assertEq(IERC20(Mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_Fork_Flash_RevertsWithoutFee() public {
        // Principal back, fee missing → balance0Before + fee0 > balance0After
        vm.expectRevert(bytes("F0"));
        _flash(1_000_000e6, 0, Repay.PrincipalOnly);
    }

    function test_Fork_Flash_RevertsWithoutFee_Token1() public {
        // Same check for token1 (WETH) uses its own error.
        vm.expectRevert(bytes("F1"));
        _flash(0, 500 ether, Repay.PrincipalOnly);
    }

    function test_Fork_Flash_RevertsWithoutRepay() public {
        // Not repaying reverts the whole call, as if the loan never happened.
        vm.expectRevert(bytes("F0"));
        _flash(1_000_000e6, 0, Repay.Nothing);
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(this)), 0);
    }

    function test_Fork_Flash_RevertsWhenBorrowingMoreThanPool() public {
        // Can't borrow more than the pool holds: the USDC transfer fails.
        uint256 poolUsdc = IERC20(Mainnet.USDC).balanceOf(address(pool));
        vm.expectRevert(bytes("TF"));
        _flash(poolUsdc + 1, 0, Repay.Full);
    }

    function test_Fork_FlashCallback_RevertsFromFakePool() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("not pool"));
        this.uniswapV3FlashCallback(0, 0, abi.encode(FlashData(0, 0, Repay.Nothing)));
    }

    // ---------------------------------------------------------------------
    // tick ↔ token composition of a position
    // ---------------------------------------------------------------------

    /// @dev What a position would pay out if fully burned right now.
    struct Withdrawable {
        uint256 usdc; // principal, token0
        uint256 weth; // principal, token1
        uint256 feeUsdc;
        uint256 feeWeth;
    }

    /// @dev Burns the whole position on a snapshot and reverts, so the position is left untouched.
    /// decreaseLiquidity returns the principal; collect returns principal + fees, so fees = collect - principal.
    function _withdrawable(uint256 tokenId, uint128 liquidity) internal returns (Withdrawable memory w) {
        uint256 snapshot = vm.snapshotState();
        (w.usdc, w.weth) = POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        (uint256 collected0, uint256 collected1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        w.feeUsdc = collected0 - w.usdc;
        w.feeWeth = collected1 - w.weth;
        vm.revertToState(snapshot);
    }

    /// @dev The principal must equal the V3 formula at the current price:
    ///   below the range: USDC only = L·(1/√pa − 1/√pb)
    ///   in the range:    USDC = L·(1/√P − 1/√pb),  WETH = L·(√P − √pa)
    ///   above the range: WETH only = L·(√pb − √pa)
    function _assertMatchesFormula(Withdrawable memory w, int24 lower, int24 upper, uint128 liquidity) internal view {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        (uint256 usdc, uint256 weth) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(lower), TickMath.getSqrtRatioAtTick(upper), liquidity
        );
        assertEq(w.usdc, usdc);
        assertEq(w.weth, weth);
    }

    function _logWithdrawable(string memory label, Withdrawable memory w) internal {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = pool.slot0();
        // P = (sqrtPriceX96 / 2^96)^2 = WETH wei per USDC unit, so WETH in USDC units = weth · 2^192 / sqrtPriceX96^2
        uint256 wethInUsdc = Math.mulDiv(w.weth, 2 ** 192, uint256(sqrtPriceX96) * sqrtPriceX96);
        emit log_string(label);
        emit log_named_int("  tick", tick);
        emit log_named_decimal_uint("  USDC", w.usdc, 6);
        emit log_named_decimal_uint("  WETH", w.weth, 18);
        emit log_named_decimal_uint("  value in USDC", w.usdc + wethInUsdc, 6);
        emit log_named_decimal_uint("  fee USDC", w.feeUsdc, 6);
        emit log_named_decimal_uint("  fee WETH", w.feeWeth, 18);
    }

    /// One position P2 = c-600 ~ c+600. Selling USDC pushes the tick down through it:
    ///
    ///   c+600 ──────── c ────── c-305 ────── c-600 ── c-705 ──▶ (tick goes down)
    ///          [ USDC + WETH ] [ more USDC, less WETH ]   [ USDC only, inactive ]
    ///
    /// Swappers sell USDC to the pool, so while in range the position takes USDC and gives WETH.
    function test_Fork_PositionComposition_FollowsTick() public {
        int24 c = _centerTick();
        int24 lower = c - 600;
        int24 upper = c + 600;
        (uint256 tokenId, uint128 liquidity, uint256 usdcIn, uint256 wethIn) = _mint(lower, upper, MINT_USDC, MINT_WETH);

        // 1) At the mint price: both tokens, i.e. what we put in. mint rounds up and burn rounds down,
        //    so we may get back 1 wei less.
        Withdrawable memory start = _withdrawable(tokenId, liquidity);
        _logWithdrawable("start: tick c, inside the range", start);
        _assertMatchesFormula(start, lower, upper, liquidity);
        assertApproxEqAbs(start.usdc, usdcIn, 1);
        assertApproxEqAbs(start.weth, wethIn, 1);
        assertLe(start.usdc, usdcIn);
        assertLe(start.weth, wethIn);
        assertEq(start.feeUsdc + start.feeWeth, 0);

        // 2) Price down to c-305, still inside: more USDC, less WETH. Fees come in the input token only.
        _swapDownToTick(c - 305);
        Withdrawable memory mid = _withdrawable(tokenId, liquidity);
        _logWithdrawable("c-305: still inside the range", mid);
        _assertMatchesFormula(mid, lower, upper, liquidity);
        assertGt(mid.usdc, start.usdc);
        assertLt(mid.weth, start.weth);
        assertGt(mid.feeUsdc, 0);
        assertEq(mid.feeWeth, 0);

        // 3) Price down to c-705, below the range: all WETH has been sold, only USDC is left,
        //    and the position is no longer active (it stopped earning at c-600).
        _swapDownToTick(c - 705);
        Withdrawable memory below = _withdrawable(tokenId, liquidity);
        _logWithdrawable("c-705: below the range", below);
        _assertMatchesFormula(below, lower, upper, liquidity);
        assertEq(below.weth, 0);
        assertGt(below.usdc, mid.usdc);
        assertGt(below.feeUsdc, mid.feeUsdc); // earned between c-305 and c-600
        assertEq(below.feeWeth, 0);

        // Going further down changes nothing for this position: no WETH left to sell, no fees.
        _swapDownToTick(c - 905);
        Withdrawable memory further = _withdrawable(tokenId, liquidity);
        assertEq(further.usdc, below.usdc);
        assertEq(further.weth, 0);
        assertEq(further.feeUsdc, below.feeUsdc);
    }
}
