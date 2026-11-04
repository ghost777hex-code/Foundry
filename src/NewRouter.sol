// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUniswapV3MintCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

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

    // Problem 2
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);

    function burn(int24 tickLower, int24 tickUpper, uint128 amount) external returns (uint256 amount0, uint256 amount1);

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);
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

/// @dev Encoded V3 path: token (20) + fee (3) + token (20) [+ fee + token ...]
library Path {
    uint256 private constant ADDR_SIZE = 20;
    uint256 private constant FEE_SIZE = 3;
    uint256 private constant NEXT_OFFSET = ADDR_SIZE + FEE_SIZE;
    uint256 private constant POP_OFFSET = NEXT_OFFSET + ADDR_SIZE;

    function hasMultiplePools(bytes memory path) internal pure returns (bool) {
        return path.length > POP_OFFSET;
    }

    function numPools(bytes memory path) internal pure returns (uint256) {
        return ((path.length - ADDR_SIZE) / NEXT_OFFSET);
    }

    function decodeFirstPool(bytes memory path) internal pure returns (address tokenA, address tokenB, uint24 fee) {
        tokenA = _decodeAddress(path, 0);
        fee = _decodeFee(path, ADDR_SIZE);
        tokenB = _decodeAddress(path, NEXT_OFFSET);
    }

    function getFirstPool(bytes memory path, address factory) internal view returns (address pool) {
        (address tokenA, address tokenB, uint24 fee) = decodeFirstPool(path);
        pool = IUniswapV3Factory(factory).getPool(tokenA, tokenB, fee);
        require(pool != address(0), "POOL_NOT_FOUND");
    }

    function skipToken(bytes memory path) internal pure returns (bytes memory) {
        return _slice(path, ADDR_SIZE, path.length - ADDR_SIZE);
    }

    function _decodeAddress(bytes memory path, uint256 offset) private pure returns (address token) {
        assembly {
            token := shr(96, mload(add(add(path, 32), offset)))
        }
    }

    function _decodeFee(bytes memory path, uint256 offset) private pure returns (uint24 fee) {
        assembly {
            fee := shr(232, mload(add(add(path, 32), offset)))
        }
    }

    function _slice(bytes memory data, uint256 start, uint256 length) private pure returns (bytes memory result) {
        require(start + length <= data.length, "SLICE_OOB");
        result = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            result[i] = data[start + i];
        }
    }
}

contract UniswapV3Router is IERC721Receiver, IUniswapV3MintCallback {
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    address public immutable factory;
    address public immutable positionManager;

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        address data;
    }

    struct ExactInputPoolsParams {
        address tokenIn;
        address[] pools;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct AddLiquidityParams {
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
        address payer;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    mapping(address => mapping(bytes32 => uint128)) public positions;

    error Expired();
    error InsufficientOutput();
    error InvalidPool();
    error TokenNotInPool();

    constructor(address factory_, address positionManager_) {
        require(factory_ != address(0) && positionManager_ != address(0), "ZERO_ADDRESS");
        factory = factory_;
        positionManager = positionManager_;
    }

    /// @notice Exact-input swap along a standard V3 encoded path; each hop pool is resolved from `factory`.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        if (block.timestamp > params.deadline) revert Expired();
        require(params.amountIn > 0, "AMOUNT_IN");

        amountOut = params.amountIn;
        bytes memory path = params.path;

        address payer = params.data;
        while (true) {
            bool hasMultiple = Path.hasMultiplePools(path);
            address pool = Path.getFirstPool(path, factory);
            _verifyFactoryPool(pool);

            address recipient = hasMultiple ? address(this) : params.recipient;
            (address tokenIn,,) = Path.decodeFirstPool(path);
            amountOut = _exactInputSwap(pool, tokenIn, recipient, amountOut, abi.encode(payer));

            if (hasMultiple) {
                path = Path.skipToken(path);
                payer = address(this);
            } else {
                if (amountOut < params.amountOutMinimum) revert InsufficientOutput();
                return amountOut;
            }
        }
    }

    /// @notice Exact-input swap through an explicit list of pool addresses (validated against `factory`).
    function exactInputPools(ExactInputPoolsParams calldata params) external payable returns (uint256 amountOut) {
        if (block.timestamp > params.deadline) revert Expired();
        require(params.amountIn > 0 && params.pools.length > 0, "PATH");

        address tokenIn = params.tokenIn;
        amountOut = params.amountIn;
        address payer = msg.sender;

        uint256 last = params.pools.length - 1;
        for (uint256 i = 0; i < params.pools.length; ++i) {
            address pool = params.pools[i];
            _verifyFactoryPool(pool);

            address recipient = i == last ? params.recipient : address(this);
            amountOut = _exactInputSwap(pool, tokenIn, recipient, amountOut, abi.encode(payer));

            tokenIn = _outputToken(pool, tokenIn);
            payer = address(this);
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

    //  Problem 2
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        _verifyFactoryPool(msg.sender); //msg.sender is pool
        address payer = abi.decode(data, (address)); // addLiquidity's msg.sender is User
        if (amount0Owed > 0) _pay(IUniswapV3Pool(msg.sender).token0(), payer, msg.sender, amount0Owed);
        if (amount1Owed > 0) _pay(IUniswapV3Pool(msg.sender).token1(), payer, msg.sender, amount1Owed);
    }

    function addLiquidity(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        _verifyFactoryPool(pool);
        (uint160 sqrtRatioX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, amount0Desired, amount1Desired
        );

        (amount0, amount1) =
            IUniswapV3Pool(pool).mint(address(this), tickLower, tickUpper, liquidity, abi.encode(msg.sender));
        require(amount0 >= amount0Min && amount1 >= amount1Min, "Slippage");
        positions[msg.sender][keccak256(abi.encodePacked(pool, tickLower, tickUpper))] += liquidity;
    }

    function removeLiquidity(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint256 amount0, uint256 amount1) {
        _verifyFactoryPool(pool);
        require(liquidity > 0, "Zero Liquidity");
        bytes32 key = keccak256(abi.encodePacked(pool, tickLower, tickUpper));
        require(positions[msg.sender][key] >= liquidity, "Not Enough Liquidity");

        positions[msg.sender][key] -= liquidity;

        (amount0, amount1) = IUniswapV3Pool(pool).burn(tickLower, tickUpper, liquidity);
        require(amount0 >= amount0Min && amount1 >= amount1Min, "Slippage");

        IUniswapV3Pool(pool).collect(msg.sender, tickLower, tickUpper, uint128(amount0), uint128(amount1));
    }
}
