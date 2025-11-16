// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IFactory.sol";
import "./libraries/TickMath.sol";
import "./libraries/SafeCast.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/SwapMath.sol";
import "./libraries/FixedPoint128.sol";
import "./libraries/LiquidityMath.sol";

contract Pool is IPool {
    using SafeCast for uint256;
    using LowGasSafeMath for int256;
    using LowGasSafeMath for uint256;

    /// @inheritdoc IPool
    address public immutable override factory;
    /// @inheritdoc IPool
    // token0表示池子
    address public immutable override token0;
    /// @inheritdoc IPool
    address public immutable override token1;
    /// @inheritdoc IPool
    // 费率
    uint24 public immutable override fee;
    /// @inheritdoc IPool
    int24 public immutable override tickLower;
    /// @inheritdoc IPool
    int24 public immutable override tickUpper;

    /// @inheritdoc IPool
    uint160 public override sqrtPriceX96;
    /// @inheritdoc IPool
    int24 public override tick;
    /// @inheritdoc IPool
    uint128 public override liquidity;

    /// @inheritdoc IPool
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IPool
    uint256 public override feeGrowthGlobal1X128;

    // 头寸
    mapping(address => Position) positions;

    struct Position {
        // 该 Position 拥有的流动性
        uint128 liquidity;
        // 可提取的 token0 数量
        uint128 tokensOwed0;
        // 可提取的 token1 数量
        uint128 tokensOwed1;
        // token0上次提取手续费时的 feeGrowthGlobal0X128
        uint256 feeGrowthInside0LastX128;
        // token1上次提取手续费是的 feeGrowthGlobal1X128
        uint256 feeGrowthInside1LastX128;
    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // any change in liquidity
        int128 liquidityDelta;
    }

    // 交易中需要临时存储的变量
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        // 剩余交换额度
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        // 以交换额度
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the global fee growth of the input token
        // 全局交易费
        uint256 feeGrowthGlobalX128;
        // 该交易中用户转入的 token0 的数量
        uint256 amountIn;
        // 该交易中用户转出的 token1 的数量
        uint256 amountOut;
        // 该交易中的手续费，如果 zeroForOne 是 ture，则是用户转入 token0，单位是 token0 的数量，反正是 token1 的数量
        uint256 feeAmount;
    }

    // 无参构造。可以令Pool的地址是可预测的
    constructor() {
        (factory, token0, token1, tickLower, tickUpper, fee) = IFactory(
            msg.sender
        ).parameters();
    }

    // 初始化价格。将价格转换为 tick 来校验。
    // 创建pool时，定义[tickLower, tickUpper]
    function initialize(uint160 sqrtPriceX96_) external override {
        require(sqrtPriceX96_ == 0, "invalid price");
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        require(
            tick > tickLower && tick < tickUpper,
            "sqrtPriceX96_ should be within the range of [tickLower, tickUpper]"
        );
        sqrtPriceX96 = sqrtPriceX96_;
    }

    // 查询用户头寸
    function getPosition(
        address owner
    )
        external
        view
        returns (
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        return (
            positions[owner].liquidity,
            positions[owner].feeGrowthInside0LastX128,
            positions[owner].feeGrowthInside1LastX128,
            positions[owner].tokensOwed0,
            positions[owner].tokensOwed1
        );
    }

    /**
     * 添加头寸（铸造NFT）
     * @param recipient NFT接收地址
     * @param amount 要添加的流动性
     * @param data 回调到positionManager中的参数
     * @return amount0 在目标流动性下，需要的token0个数
     * @return amount1 在目标流动性下，需要的token1个数
     */
    function mint(
        address recipient,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1) {
        require(recipient != address(0), "invalid recipient");
        require(amount > 0, "amount must greater than 0");

        // 通过 `_modifyPosition` 函数，基于传入的 `amount` 计算出 `amount0` 和 `amount1`，并返回这两个值
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams(recipient, int128(amount))
        );
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Befor;
        uint256 balance1Befor;
        if (amount0 > 0) {
            balance0Befor = balance0();
        }
        if (amount1 > 0) {
            balance1Befor = balance1();
        }

        // 回调positionManager.mintCallback, 将会把token0,token1转到 本合约
        IMintCallback(msg.sender).mintCallback(amount0, amount1, data);
        // 回调到其他合约了。查看余额，以确认回调成功
        if (amount0 > 0) {
            require((balance0Befor + amount0) <= balance0(), "MO");
        }
        if (amount1 > 0) {
            require((balance1Befor + amount1) <= balance1(), "M1");
        }
    }

    // 工具类根据新增的流动性计算amount0,amount1
    // 记录手续费
    function _modifyPosition(
        ModifyPositionParams memory params
    ) internal returns (int256 amount0, int256 amount1) {
        // 通过新增的流动性计算 amount0 和 amount1
        // 参考 UniswapV3 的代码

        amount0 = SqrtPriceMath.getAmount0Delta(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickUpper),
            params.liquidityDelta
        );

        amount1 = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceX96,
            params.liquidityDelta
        );

        Position storage position = positions[params.owner];

        // 提取手续费，计算从上一次提取到当前的手续费
        uint128 tokensOwed0 = uint128(
            FullMath.mulDiv(
                // feeGrowthGlobal0X128 记录从创建到现在，每个流动性累计产生的 token0 的手续费
                //              - 上次提取手续费时的 feeGrowthGlobal0X128
                feeGrowthGlobal0X128 - position.feeGrowthInside0LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );
        uint128 tokensOwed1 = uint128(
            FullMath.mulDiv(
                feeGrowthGlobal1X128 - position.feeGrowthInside1LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );

        // 更新提取手续费的记录，同步到当前最新的 feeGrowthGlobal0X128，代表都提取完了
        position.feeGrowthInside0LastX128 = feeGrowthGlobal0X128;
        position.feeGrowthInside1LastX128 = feeGrowthGlobal1X128;

        // 把可以提取的手续费记录到 tokensOwed0 和 tokensOwed1 中
        // LP 可以通过 collect 来最终提取到用户自己账户上
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            position.tokensOwed0 += tokensOwed0;
            position.tokensOwed1 += tokensOwed1;
        }

        // 修改 liquidity
        liquidity = LiquidityMath.addDelta(liquidity, params.liquidityDelta);
        position.liquidity = LiquidityMath.addDelta(
            position.liquidity,
            params.liquidityDelta
        );
    }

    function balance0() internal view returns (uint256) {
        // 低级调用
        (bool success, bytes memory data) = token0.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        require(success && data.length >= 32, "IERC20.BalanceOf error");
        return abi.decode(data, (uint256));
    }

    function balance1() internal view returns (uint256) {
        // 低级调用
        (bool success, bytes memory data) = token1.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        // uint256 32字节
        require(success && data.length >= 32, "IERC20.BalanceOf error");
        return abi.decode(data, (uint256));
    }

    /**
     * 提取手续费
     * @param recipient 代币接收地址
     * @param amount0Requested token0期望数量
     * @param amount1Requested token1期望数量
     * @return amount0
     * @return amount1
     */
    function collect(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1) {
        Position storage position = positions[msg.sender];

        // 期望提取金额不能超出余额
        amount0 = amount0Requested > position.tokensOwed0
            ? position.tokensOwed0
            : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1
            ? position.tokensOwed1
            : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }
    }

    /**
     * 移除流动性
     * @param amount 流动性
     * @return amount0 退回的token0
     * @return amount1 退回的token1
     */
    function burn(
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1) {
        require(amount > 0, "amount must be greater than 0");
        Position memory position = positions[msg.sender];
        require(amount <= position.liquidity, "amount is not enough");

        // 移除流动性，流动性传入负数
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams(msg.sender, -int128(amount))
        );
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (
                positions[msg.sender].tokensOwed0,
                positions[msg.sender].tokensOwed1
            ) = (
                positions[msg.sender].tokensOwed0 + uint128(amount0),
                positions[msg.sender].tokensOwed1 + uint128(amount1)
            );
        }
    }

    /**
     * 交换代币
     * @param recipient 代币接收地址
     * @param zeroForOne true 表示 0 => 1,否则 1 => 0
     * @param amountSpecified 指定金额。 > 0表示要支付的token0数量，否则代表要获取的token1数量
     * @param sqrtPriceLimitX96 最低价格
     * @param data 回调参数
     * @return amount0
     * @return amount1
     */
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, "amountSpecified can not be 0");

        // 判断当前价格是否满足交易的条件
        // TODO ? 为什么正向的是小于当前价格，而反向是大于当前价格
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < sqrtPriceX96 &&
                    sqrtPriceLimitX96 > TickMath.MIN_SQRT_PRICE
                : sqrtPriceLimitX96 > sqrtPriceX96 &&
                    sqrtPriceLimitX96 < TickMath.MAX_SQRT_PRICE,
            "SPL"
        );

        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            // the amount remaining to be swapped in/out of the input/output asset
            // 剩余交换额度
            amountSpecifiedRemaining: amountSpecified,
            // the amount already swapped out/in of the output/input asset
            // 以交换额度
            amountCalculated: 0,
            // current sqrt(price)
            sqrtPriceX96: sqrtPriceX96,
            // the global fee growth of the input token
            // 全局交易费
            feeGrowthGlobalX128: zeroForOne
                ? feeGrowthGlobal0X128
                : feeGrowthGlobal1X128,
            // 该交易中用户转入的 token0 的数量
            amountIn: 0,
            // 该交易中用户转出的 token1 的数量
            amountOut: 0,
            // 该交易中的手续费，如果 zeroForOne 是 ture，则是用户转入 token0，单位是 token0 的数量，反正是 token1 的数量
            feeAmount: 0
        });

        // 计算交易的上下限，基于 tick 计算价格
        uint160 sqrtPriceX96Lower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtPriceAtTick(tickUpper);
        // 计算用户交易价格的限制，如果是 zeroForOne 是 true，说明用户会换入 token0，会压低 token0 的价格（也就是池子的价格），
        //      所以要限制最低价格不能超过 sqrtPriceX96Lower
        uint160 sqrtPriceX96PoolLimit = zeroForOne
            ? sqrtPriceX96Lower
            : sqrtPriceX96Upper;
        // 在指定价格和数量的情况下，该池子可以提供的token0和token1
        // 计算交易的具体数值
        (
            state.sqrtPriceX96,
            state.amountIn,
            state.amountOut,
            state.feeAmount
        ) = SwapMath.computeSwapStep(
            sqrtPriceX96,
            (
                zeroForOne
                    ? sqrtPriceX96PoolLimit < sqrtPriceLimitX96
                    : sqrtPriceX96PoolLimit > sqrtPriceLimitX96
            )
                ? sqrtPriceLimitX96
                : sqrtPriceX96PoolLimit,
            liquidity,
            amountSpecified,
            fee
        );

        // 更新新的价格
        sqrtPriceX96 = state.sqrtPriceX96;

        // 计算手续费
        // 手续费 / 流动性，每流动性的手续费？
        state.feeGrowthGlobalX128 += FullMath.mulDiv(
            state.feeAmount,
            FixedPoint128.Q128,
            liquidity
        );

        // 更新手续费相关信息
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }

        // 计算交易后，用户手里的token0,token1数量
        if (exactInput) {
            state.amountSpecifiedRemaining -= (state.amountIn + state.feeAmount)
                .toInt256();
            state.amountCalculated = state.amountCalculated.sub(
                state.amountOut.toInt256()
            );
        } else {
            state.amountSpecifiedRemaining += state.amountOut.toInt256();
            state.amountCalculated = state.amountCalculated.add(
                (state.amountIn + state.feeAmount).toInt256()
            );
        }

        (amount0, amount1) = zeroForOne == exactInput
            ? (
                amountSpecified - state.amountSpecifiedRemaining,
                state.amountCalculated
            )
            : (
                state.amountCalculated,
                amountSpecified - state.amountSpecifiedRemaining
            );

        if (zeroForOne) {
            // callback 中需要给 Pool 转入 token
            uint256 balance0Before = balance0();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance0Before.add(uint256(amount0)) <= balance0(), "IIA");

            // 转 Token 给用户
            if (amount1 < 0) {
                TransferHelper.safeTransfer(
                    token1,
                    recipient,
                    uint256(-amount1)
                );
            }
        } else {
            // callback 中需要给 Pool 转入 token
            uint256 balance1Before = balance1();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), "IIA");

            // 转 Token 给用户
            if (amount0 < 0)
                TransferHelper.safeTransfer(
                    token0,
                    recipient,
                    uint256(-amount0)
                );
        }
    }
}
