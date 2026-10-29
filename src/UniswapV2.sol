// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Callee} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/// @notice Uniswap v2 without the router: talks to the factory and pairs directly.
contract UniswapV2 is IUniswapV2Callee {
    using SafeERC20 for IERC20;

    /// @dev Passed through pair.swap() into uniswapV2Call so the callback knows what to pay.
    struct CallbackData {
        address tokenA; // token paid in
        address tokenB; // token received
        uint256 amountA;
        address payer;
    }

    IUniswapV2Factory public immutable factory;

    constructor(IUniswapV2Factory factory_) {
        factory = factory_;
    }

    // ---------------------------------------------------------------------
    // Step 1: add liquidity (no callback: push tokens to the pair, then pair.mint)
    // ---------------------------------------------------------------------

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // 1. Find the pair, or create it on the first deposit.
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) pair = factory.createPair(tokenA, tokenB);

        // 2. Work out how much of each token to deposit at the current pool ratio.
        (amountA, amountB) = _liquidityAmounts(IUniswapV2Pair(pair), tokenA, tokenB, amountADesired, amountBDesired);
        if (amountA < amountAMin || amountB < amountBMin) revert();

        // 3. Send both tokens straight to the pair...
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        // 4. ...then mint() compares balances against reserves and mints LP for the difference.
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    // ---------------------------------------------------------------------
    // Step 2: swap (callback: pair sends output first, we pay input in uniswapV2Call)
    // ---------------------------------------------------------------------

    /// @notice Swaps exactly `amountA` of `tokenA` for `tokenB`. Approve this contract for `tokenA` first.
    function swapExactTokensForTokens(address tokenA, address tokenB, uint256 amountA, uint256 amountBMin, address to)
        external
        returns (uint256 amountB)
    {
        // 1. Find the pair and compute the output with the 0.3% fee.
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert();
        (uint256 reserveA, uint256 reserveB) = _getReserves(IUniswapV2Pair(pair), tokenA, tokenB);
        amountB = getAmountOut(amountA, reserveA, reserveB);
        if (amountB < amountBMin) revert();

        // 2. Flash swap: pair sends tokenB here, then calls uniswapV2Call (step 3).
        _flashSwap(IUniswapV2Pair(pair), tokenA, tokenB, amountA, amountB);

        // 4. The pair accepted our payment (K check passed); forward tokenB to the recipient.
        IERC20(tokenB).safeTransfer(to, amountB);
    }

    /// @inheritdoc IUniswapV2Callee
    function uniswapV2Call(address sender, uint256, uint256, bytes calldata data) external override {
        CallbackData memory cb = abi.decode(data, (CallbackData));

        // Anyone can call this function, so check it is the real pair, during a swap we started.
        // Without this, a fake "pair" could make us transferFrom any user who approved us.
        if (msg.sender != factory.getPair(cb.tokenA, cb.tokenB)) revert();
        if (sender != address(this)) revert();

        // 3. We already hold tokenB; pay tokenA now. After we return, the pair checks K.
        IERC20(cb.tokenA).safeTransferFrom(cb.payer, msg.sender, cb.amountA);
    }

    function _flashSwap(IUniswapV2Pair pair, address tokenA, address tokenB, uint256 amountA, uint256 amountB) private {
        // The pair only knows token0/token1 (sorted by address); tokenB goes out on its side.
        (uint256 amount0Out, uint256 amount1Out) = tokenA < tokenB ? (uint256(0), amountB) : (amountB, uint256(0));
        // Non-empty `data` turns this into a flash swap. The pair calls back the swap's `to`,
        // not msg.sender, so `to` must be this contract.
        pair.swap(amount0Out, amount1Out, address(this), abi.encode(CallbackData(tokenA, tokenB, amountA, msg.sender)));
    }

    // ---------------------------------------------------------------------
    // Step 3: remove liquidity (no callback: push LP to the pair, then pair.burn)
    // ---------------------------------------------------------------------
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) external returns (uint256 amountA, uint256 amountB) {
        //1. Find the pair. It is also the LP token (the pair contract is an ERC20).
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert();

        //2. Send the caller's LP tokens to the pair. Approve this contract for the LP token first.
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);

        //3. burn() destroys the LP the pair holds and sends both tokens to `to`, pro rata:
        //   amount0 = liquidity * balance0 / totalSupply (same for token1). It returns them in token0/token1 order.
        (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pair).burn(to);

        //4. Map token0/token1 back to A/B, then check slippage.
        (amountA, amountB) = tokenA < tokenB ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin || amountB < amountBMin) revert();
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Converts `amountA` of A into the equal-value amount of B at the current reserves.
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256) {
        if (amountA == 0) revert();
        if (reserveA == 0 || reserveB == 0) revert();
        return amountA * reserveB / reserveA;
    }

    /// @dev Output for `amountIn` after the 0.3% fee, keeping reserveIn * reserveOut constant.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        if (amountIn == 0) revert();
        if (reserveIn == 0 || reserveOut == 0) revert();
        uint256 amountInWithFee = amountIn * 997;
        return amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee);
    }

    function _getReserves(IUniswapV2Pair pair, address tokenA, address tokenB)
        private
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        if (tokenA == tokenB) revert();
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        // The pair stores reserves sorted by address (token0 < token1).
        (reserveA, reserveB) = tokenA < tokenB ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function _liquidityAmounts(
        IUniswapV2Pair pair,
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) private view returns (uint256 amountA, uint256 amountB) {
        (uint256 reserveA, uint256 reserveB) = _getReserves(pair, tokenA, tokenB);
        // Empty pool: the first depositor sets the price.
        if (reserveA == 0 && reserveB == 0) return (amountADesired, amountBDesired);

        // Use all of one side and only the matching amount of the other, so nothing is donated.
        uint256 amountBOptimal = quote(amountADesired, reserveA, reserveB);
        if (amountBOptimal <= amountBDesired) return (amountADesired, amountBOptimal);
        return (quote(amountBDesired, reserveB, reserveA), amountBDesired);
    }
}
