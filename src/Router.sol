// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title UniswapV3Router
/// @notice Swap and manage concentrated liquidity via Uniswap V3 factory pools.
/// Users approve ERC20s to this router; swaps pay owed tokens from `payer` encoded in callback data.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3Pool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

library TransferHelper {
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(IERC20(token).transferFrom(from, to, value), "STF");
    }

    function safeTransfer(address token, address to, uint256 value) internal {
        require(IERC20(token).transfer(to, value), "ST");
    }
}

contract UniswapV3Router is IERC721Receiver {
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    address public immutable factory;
    address public immutable positionManager;

    struct ExactInputPoolsParams {
        address tokenIn;
        address[] pools;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    error Expired();
    error InsufficientOutput();
    error InvalidPool();
    error TokenNotInPool();

    constructor(address factory_, address positionManager_) {
        require(factory_ != address(0) && positionManager_ != address(0), "ZERO_ADDRESS");
        factory = factory_;
        positionManager = positionManager_;
    }

    /// @notice Exact-input swap through an explicit list of pool addresses (validated against `factory`).
    function exactInputPools(ExactInputPoolsParams calldata params) external payable returns (uint256 amountOut) {
        if (block.timestamp > params.deadline) revert Expired();
        require(params.amountIn > 0 && params.pools.length > 0, "PATH");

        bytes memory callbackData = abi.encode(address(this));
        address tokenIn = params.tokenIn;
        amountOut = params.amountIn;

        uint256 last = params.pools.length - 1;
        for (uint256 i = 0; i < params.pools.length; ++i) {
            address pool = params.pools[i];
            _verifyFactoryPool(pool);

            address recipient = address(this);
            amountOut = _exactInputSwap(pool, tokenIn, recipient, amountOut, callbackData);

            tokenIn = _outputToken(pool, tokenIn);
        }

        if (amountOut < params.amountOutMinimum) revert InsufficientOutput();
        return amountOut;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        address payer = abi.decode(data, (address));
        address pool = msg.sender;
        _verifyFactoryPool(pool);

        if (amount0Delta > 0) {
            _pay(IUniswapV3Pool(pool).token0(), payer, pool, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            _pay(IUniswapV3Pool(pool).token1(), payer, pool, uint256(amount1Delta));
        }
    }

    function _pay(address token, address payer, address recipient, uint256 value) internal {
        if (payer == address(this)) {
            TransferHelper.safeTransfer(token, recipient, value);
        } else {
            TransferHelper.safeTransferFrom(token, payer, recipient, value);
        }
    }

    function _exactInputSwap(address pool, address tokenIn, address recipient, uint256 amountIn, bytes memory data)
        internal
        returns (uint256 amountOut)
    {
        bool zeroForOne = tokenIn == IUniswapV3Pool(pool).token0();
        if (!zeroForOne && tokenIn != IUniswapV3Pool(pool).token1()) revert TokenNotInPool();

        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;

        (int256 amount0, int256 amount1) =
            IUniswapV3Pool(pool).swap(recipient, zeroForOne, int256(amountIn), sqrtPriceLimitX96, data);

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    function _outputToken(address pool, address tokenIn) internal view returns (address tokenOut) {
        address t0 = IUniswapV3Pool(pool).token0();
        if (tokenIn == t0) return IUniswapV3Pool(pool).token1();
        if (tokenIn == IUniswapV3Pool(pool).token1()) return t0;
        revert TokenNotInPool();
    }

    function _verifyFactoryPool(address pool) internal view {
        if (pool == address(0)) revert InvalidPool();
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        if (p.factory() != factory) revert InvalidPool();
        address expected = IUniswapV3Factory(factory).getPool(p.token0(), p.token1(), p.fee());
        if (expected != pool) revert InvalidPool();
    }
}
