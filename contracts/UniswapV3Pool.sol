// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "prb-math/PRBMath.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV3FlashCallback.sol";
import "./interfaces/IUniswapV3MintCallback.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";

import "./lib/FixedPoint128.sol";
import "./lib/LiquidityMath.sol";
import "./lib/Math.sol";
import "./lib/Oracle.sol";
import "./lib/Position.sol";
import "./lib/SwapMath.sol";
import "./lib/Tick.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";

import {IBonsaiRelay} from "bonsai/IBonsaiRelay.sol";
import {BonsaiCallbackReceiver} from "./BonsaiCallbackReceiver.sol";

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {toDaysWadUnsafe} from "solmate/utils/SignedWadMath.sol";

import {LinearVRGDA} from "VRGDAs/LinearVRGDA.sol";

contract UniswapV3Pool is IUniswapV3Pool, BonsaiCallbackReceiver, LinearVRGDA {
    using Oracle for Oracle.Observation[65535];
    using Position for Position.Info;
    using Position for mapping(bytes32 => Position.Info);
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);

    error AlreadyInitialized();
    error FlashLoanNotPaid();
    error InsufficientInputAmount();
    error InvalidPriceLimit();
    error InvalidTickRange();
    error NotEnoughLiquidity();
    error ZeroLiquidity();
    error InvalidJournal();
    error EmptySwapRequests();
    error CannotReleaseSwapRequest();
    error InvalidSwapRequestRoot();
    error SwapRequestTimedOut();
    error SwapRequestAlreadyExecuted();
    error SwapRequestAlreadyRequested();

    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Collect(
        address indexed owner,
        address recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint256 amount0,
        uint256 amount1
    );

    event Flash(address indexed recipient, uint256 amount0, uint256 amount1);

    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld, uint16 observationCardinalityNextNew
    );

    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    event SettleSwap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint256 cycles_used
    );

    /// @notice Address of the Bonsai relay contract.
    address public relay;

    /// @notice Image ID of the only zkVM binary to accept callbacks from.
    bytes32 public immutable swapImageId;

    /// @notice Gas limit set on the callback from Bonsai.
    /// @dev Should be set to the maximum amount of gas your callback might reasonably consume.
    uint64 private constant BONSAI_CALLBACK_GAS_LIMIT = 100000;

    // Pool parameters
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable tickSpacing;
    uint24 public immutable fee;

    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    // First slot will contain essential data
    struct Slot0 {
        // Current sqrt(P)
        uint160 sqrtPriceX96;
        // Current tick
        int24 tick;
        // Most recent observation index
        uint16 observationIndex;
        // Maximum number of observations
        uint16 observationCardinality;
        // Next maximum number of observations
        uint16 observationCardinalityNext;
    }

    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 feeGrowthGlobalX128;
        uint128 liquidity;
    }

    struct StepState {
        uint160 sqrtPriceStartX96;
        int24 nextTick;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    struct SwapRequest {
        bool active;
        address recipient;
        address sender;
        bool zeroForOne;
        uint256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        bytes data;
        uint32 duration;
        uint32 timestamp;
    }

    SwapRequest public request;

    uint32 public LOCK_TIMEOUT = 1 minutes;

    int256 public cache_lastAmount0;
    int256 public cache_lastAmount1;

    uint256 public locksSold; // The total number of locks sold so far.

    uint256 public immutable startTime = block.timestamp; // When VRGDA sales begun.

    Slot0 public slot0;

    // Amount of liquidity, L.
    uint128 public liquidity;

    mapping(int24 => Tick.Info) public ticks;
    mapping(int16 => uint256) public tickBitmap;
    mapping(bytes32 => Position.Info) public positions;
    Oracle.Observation[65535] public observations;

    modifier PoolLocked() {
        require(isPoolLocked(), "POOL_NOT_LOCKED");
        _;
    }

    modifier PoolNotLocked() {
        require(!isPoolLocked(), "POOL_LOCKED");
        _;
    }

    modifier RequestHasNotTimedout() {
        require(!hasLockTimedOut(), "REQUEST_TIMED_OUT");
        _;
    }

    constructor()
        LinearVRGDA(
            69.42e18, // Target price.
            0.31e18, // Price decay percent.
            2e18 // Per time unit.
        )
    {
        (factory, token0, token1, tickSpacing, fee, relay, swapImageId) =
            IUniswapV3PoolDeployer(msg.sender).parameters();

        bonsaiRelay = IBonsaiRelay(relay);
    }

    function initialize(uint160 sqrtPriceX96) public {
        if (slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext
        });
    }

    struct ModifyPositionParams {
        address owner;
        int24 lowerTick;
        int24 upperTick;
        int128 liquidityDelta;
    }

    function _modifyPosition(ModifyPositionParams memory params)
        internal
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        // gas optimizations
        Slot0 memory slot0_ = slot0;
        uint256 feeGrowthGlobal0X128_ = feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128_ = feeGrowthGlobal1X128;

        position = positions.get(params.owner, params.lowerTick, params.upperTick);

        bool flippedLower = ticks.update(
            params.lowerTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            false
        );
        bool flippedUpper = ticks.update(
            params.upperTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            true
        );

        if (flippedLower) {
            tickBitmap.flipTick(params.lowerTick, int24(tickSpacing));
        }

        if (flippedUpper) {
            tickBitmap.flipTick(params.upperTick, int24(tickSpacing));
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks.getFeeGrowthInside(
            params.lowerTick, params.upperTick, slot0_.tick, feeGrowthGlobal0X128_, feeGrowthGlobal1X128_
        );

        position.update(params.liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        if (slot0_.tick < params.lowerTick) {
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        } else if (slot0_.tick < params.upperTick) {
            amount0 = Math.calcAmount0Delta(
                slot0_.sqrtPriceX96, TickMath.getSqrtRatioAtTick(params.upperTick), params.liquidityDelta
            );

            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick), slot0_.sqrtPriceX96, params.liquidityDelta
            );

            liquidity = LiquidityMath.addLiquidity(liquidity, params.liquidityDelta);
        } else {
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        }
    }

    function mint(address owner, int24 lowerTick, int24 upperTick, uint128 amount, bytes calldata data)
        external
        PoolNotLocked
        returns (uint256 amount0, uint256 amount1)
    {
        if (lowerTick >= upperTick || lowerTick < TickMath.MIN_TICK || upperTick > TickMath.MAX_TICK) {
            revert InvalidTickRange();
        }

        if (amount == 0) revert ZeroLiquidity();

        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: owner,
                lowerTick: lowerTick,
                upperTick: upperTick,
                liquidityDelta: int128(amount)
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;

        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();

        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);

        if (amount0 > 0 && balance0Before + amount0 > balance0()) {
            revert InsufficientInputAmount();
        }

        if (amount1 > 0 && balance1Before + amount1 > balance1()) {
            revert InsufficientInputAmount();
        }

        emit Mint(msg.sender, owner, lowerTick, upperTick, amount, amount0, amount1);
    }

    function burn(int24 lowerTick, int24 upperTick, uint128 amount)
        public
        PoolNotLocked
        returns (uint256 amount0, uint256 amount1)
    {
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                lowerTick: lowerTick,
                upperTick: upperTick,
                liquidityDelta: -(int128(amount))
            })
        );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) =
                (position.tokensOwed0 + uint128(amount0), position.tokensOwed1 + uint128(amount1));
        }

        emit Burn(msg.sender, lowerTick, upperTick, amount, amount0, amount1);
    }

    function collect(
        address recipient,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) public PoolNotLocked returns (uint128 amount0, uint128 amount1) {
        Position.Info storage position = positions.get(msg.sender, lowerTick, upperTick);

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            IERC20(token0).transfer(recipient, amount0);
        }

        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            IERC20(token1).transfer(recipient, amount1);
        }

        emit Collect(msg.sender, recipient, lowerTick, upperTick, amount0, amount1);
    }

    function swap(
        address recipient,
        bool zeroForOne,
        uint256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) public PoolNotLocked returns (int256 amount0, int256 amount1) {
        // Caching for gas saving
        Slot0 memory slot0_ = slot0;
        uint128 liquidity_ = liquidity;

        if (
            zeroForOne
                ? sqrtPriceLimitX96 > slot0_.sqrtPriceX96 || sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 < slot0_.sqrtPriceX96 || sqrtPriceLimitX96 > TickMath.MAX_SQRT_RATIO
        ) revert InvalidPriceLimit();

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            liquidity: liquidity_
        });

        while (state.amountSpecifiedRemaining > 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepState memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.nextTick,) = tickBitmap.nextInitializedTickWithinOneWord(state.tick, int24(tickSpacing), zeroForOne);

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            state.amountSpecifiedRemaining -= step.amountIn + step.feeAmount;
            state.amountCalculated += step.amountOut;

            if (state.liquidity > 0) {
                state.feeGrowthGlobalX128 += PRBMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                int128 liquidityDelta = ticks.cross(
                    step.nextTick,
                    (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                    (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128)
                );

                if (zeroForOne) liquidityDelta = -liquidityDelta;

                state.liquidity = LiquidityMath.addLiquidity(state.liquidity, liquidityDelta);

                if (state.liquidity == 0) revert NotEnoughLiquidity();

                state.tick = zeroForOne ? step.nextTick - 1 : step.nextTick;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        if (state.tick != slot0_.tick) {
            (uint16 observationIndex, uint16 observationCardinality) = observations.write(
                slot0_.observationIndex,
                _blockTimestamp(),
                slot0_.tick,
                slot0_.observationCardinality,
                slot0_.observationCardinalityNext
            );

            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) =
                (state.sqrtPriceX96, state.tick, observationIndex, observationCardinality);
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        if (liquidity_ != state.liquidity) liquidity = state.liquidity;

        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }

        (amount0, amount1) = zeroForOne
            ? (int256(amountSpecified - state.amountSpecifiedRemaining), -int256(state.amountCalculated))
            : (-int256(state.amountCalculated), int256(amountSpecified - state.amountSpecifiedRemaining));

        if (zeroForOne) {
            IERC20(token1).transfer(recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            if (balance0Before + uint256(amount0) > balance0()) {
                revert InsufficientInputAmount();
            }
        } else {
            IERC20(token0).transfer(recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            if (balance1Before + uint256(amount1) > balance1()) {
                revert InsufficientInputAmount();
            }
        }

        emit Swap(msg.sender, recipient, amount0, amount1, slot0.sqrtPriceX96, state.liquidity, slot0.tick);
    }

    function requestSwap(
        address recipient,
        bool zeroForOne,
        uint256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) public payable PoolNotLocked returns (uint256 lockId) {
        unchecked {
            // Note: By using toDaysWadUnsafe(block.timestamp - startTime) we are establishing that 1 "unit of time" is 1 day.
            uint256 price = getVRGDAPrice(toDaysWadUnsafe(block.timestamp - startTime), lockId = locksSold++);

            require(msg.value >= price, "UNDERPAID"); // Don't allow underpaying.

            _lockPool(recipient, msg.sender, zeroForOne, amountSpecified, sqrtPriceLimitX96, data);

            // Caching for gas saving
            Slot0 memory slot0_ = slot0;

            (int24 nextTick,) =
                tickBitmap.nextInitializedTickWithinOneWord(slot0_.tick, int24(tickSpacing), request.zeroForOne);

            uint160 sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(nextTick);

            bonsaiRelay.requestCallback(
                swapImageId,
                abi.encode(
                    keccak256(abi.encode(request)),
                    slot0_.sqrtPriceX96,
                    (
                        request.zeroForOne
                            ? sqrtPriceNextX96 < request.sqrtPriceLimitX96
                            : sqrtPriceNextX96 > request.sqrtPriceLimitX96
                    ) ? request.sqrtPriceLimitX96 : sqrtPriceNextX96,
                    liquidity,
                    request.amountSpecified,
                    fee
                ),
                address(this),
                this.settleSwap.selector,
                BONSAI_CALLBACK_GAS_LIMIT
            );

            // Note: We do this at the end to avoid creating a reentrancy vector.
            // Refund the user any ETH they spent over the current price of the request.
            // Unchecked is safe here because we validate msg.value >= price above.
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
        }
    }

    /// @notice Callback function logic for processing verified journals from Bonsai.
    function settleSwap(
        bytes32 request_root,
        uint160 sqrt_p,
        uint256 amount_in,
        uint256 amount_out,
        uint256 fee_amount,
        uint256 cycles_used
    )
        external
        onlyBonsaiCallback(swapImageId)
        PoolLocked
        RequestHasNotTimedout
        returns (int256 amount0, int256 amount1)
    {
        if (request_root != keccak256(abi.encode(request))) revert InvalidSwapRequestRoot();

        // Caching for gas saving
        Slot0 memory slot0_ = slot0;
        uint128 liquidity_ = liquidity;

        if (
            request.zeroForOne
                ? request.sqrtPriceLimitX96 > slot0_.sqrtPriceX96 || request.sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO
                : request.sqrtPriceLimitX96 < slot0_.sqrtPriceX96 || request.sqrtPriceLimitX96 > TickMath.MAX_SQRT_RATIO
        ) revert InvalidPriceLimit();

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: request.amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick,
            feeGrowthGlobalX128: request.zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            liquidity: liquidity_
        });

        while (state.amountSpecifiedRemaining > 0 && state.sqrtPriceX96 != request.sqrtPriceLimitX96) {
            StepState memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.nextTick,) =
                tickBitmap.nextInitializedTickWithinOneWord(state.tick, int24(tickSpacing), request.zeroForOne);

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

            // Loading journal data
            state.sqrtPriceX96 = sqrt_p;
            step.amountIn = amount_in;
            step.amountOut = amount_out;
            step.feeAmount = fee_amount;

            state.amountSpecifiedRemaining -= step.amountIn + step.feeAmount;
            state.amountCalculated += step.amountOut;

            if (state.liquidity > 0) {
                state.feeGrowthGlobalX128 += PRBMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                int128 liquidityDelta = ticks.cross(
                    step.nextTick,
                    (request.zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                    (request.zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128)
                );

                if (request.zeroForOne) liquidityDelta = -liquidityDelta;

                state.liquidity = LiquidityMath.addLiquidity(state.liquidity, liquidityDelta);

                if (state.liquidity == 0) revert NotEnoughLiquidity();

                state.tick = request.zeroForOne ? step.nextTick - 1 : step.nextTick;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        if (state.tick != slot0_.tick) {
            (uint16 observationIndex, uint16 observationCardinality) = observations.write(
                slot0_.observationIndex,
                _blockTimestamp(),
                slot0_.tick,
                slot0_.observationCardinality,
                slot0_.observationCardinalityNext
            );

            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) =
                (state.sqrtPriceX96, state.tick, observationIndex, observationCardinality);
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        if (liquidity_ != state.liquidity) liquidity = state.liquidity;

        if (request.zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }

        (amount0, amount1) = request.zeroForOne
            ? (int256(request.amountSpecified - state.amountSpecifiedRemaining), -int256(state.amountCalculated))
            : (-int256(state.amountCalculated), int256(request.amountSpecified - state.amountSpecifiedRemaining));

        if (request.zeroForOne) {
            IERC20(token1).transfer(request.recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(request.sender).uniswapV3SwapCallback(amount0, amount1, request.data);
            if (balance0Before + uint256(amount0) > balance0()) {
                revert InsufficientInputAmount();
            }
        } else {
            IERC20(token0).transfer(request.recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(request.sender).uniswapV3SwapCallback(amount0, amount1, request.data);
            if (balance1Before + uint256(amount1) > balance1()) {
                revert InsufficientInputAmount();
            }
        }

        emit SettleSwap(
            request.sender,
            request.recipient,
            amount0,
            amount1,
            slot0.sqrtPriceX96,
            state.liquidity,
            slot0.tick,
            cycles_used
        );

        _unlockPool();

        (cache_lastAmount0, cache_lastAmount1) = (amount0, amount1);
    }

    function timeoutLock() public {
        require(hasLockTimedOut(), "NOT_TIMED_OUT");

        _unlockPool();
    }

    function hasLockTimedOut() public view PoolLocked returns (bool timedOut) {
        timedOut = _blockTimestamp() - request.timestamp > request.duration;
    }

    function isPoolLocked() public view returns (bool) {
        return request.active;
    }

    function flash(uint256 amount0, uint256 amount1, bytes calldata data) public {
        uint256 fee0 = Math.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = Math.mulDivRoundingUp(amount1, fee, 1e6);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        if (amount0 > 0) IERC20(token0).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(token1).transfer(msg.sender, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        if (IERC20(token0).balanceOf(address(this)) < balance0Before + fee0) {
            revert FlashLoanNotPaid();
        }
        if (IERC20(token1).balanceOf(address(this)) < balance1Before + fee1) {
            revert FlashLoanNotPaid();
        }

        emit Flash(msg.sender, amount0, amount1);
    }

    function observe(uint32[] calldata secondsAgos) public view returns (int56[] memory tickCumulatives) {
        return observations.observe(
            _blockTimestamp(), secondsAgos, slot0.tick, slot0.observationIndex, slot0.observationCardinality
        );
    }

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) public {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext;
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext);

        if (observationCardinalityNextNew != observationCardinalityNextOld) {
            slot0.observationCardinalityNext = observationCardinalityNextNew;
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    //
    // INTERNAL
    //
    ////////////////////////////////////////////////////////////////////////////
    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }

    function _blockTimestamp() internal view returns (uint32 timestamp) {
        timestamp = uint32(block.timestamp);
    }

    function _lockPool(
        address recipient,
        address sender,
        bool zeroForOne,
        uint256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) internal PoolNotLocked {
        request = SwapRequest({
            active: true,
            recipient: recipient,
            sender: sender,
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            data: data,
            duration: LOCK_TIMEOUT,
            timestamp: _blockTimestamp()
        });
    }

    function _unlockPool() internal PoolLocked {
        request.active = false;
    }
}
