// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IPositionManager.sol";
import "./interfaces/IPoolManager.sol";
import "./interfaces/IPool.sol";

import "./libraries/LiquidityAmounts.sol";
import "./libraries/TickMath.sol";
import "./libraries/FixedPoint128.sol";

/**
 * @title 头寸管理，与前端交互
 */
contract PositionManager is IPositionManager, ERC721 {
    // 保存 PoolManager 合约地址
    IPoolManager public poolManager;
    // 保存所有头寸信息
    mapping(uint256 => PositionInfo) positions;
    uint256 private _nextId = 1;

    constructor(address _poolManager) ERC721("MetaNodeSwapPosition", "MNSP") {
        poolManager = IPoolManager(_poolManager);
    }

    function getAllPositions()
        external
        view
        returns (PositionInfo[] memory positionInfo)
    {
        positionInfo = new PositionInfo[](_nextId - 1);
        for (uint i = 0; i < _nextId - 1; i++) {
            positionInfo[i] = positions[i + 1];
        }
        return positionInfo;
    }

    // 添加流动性，铸造NFT
    function mint(
        MintParams calldata params
    )
        external
        payable
        returns (
            uint256 positionId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        address poolAddress = poolManager.getPool(
            params.token0,
            params.token1,
            params.index
        );
        IPool pool = IPool(poolAddress);

        // 计算流动性
        uint160 sqrtRatioAX96Lower = TickMath.getSqrtPriceAtTick(
            pool.tickLower()
        );
        uint160 sqrtRatioAX96Upper = TickMath.getSqrtPriceAtTick(
            pool.tickUpper()
        );

        // 基于池的当前价格、边界价格、给定数量的token0,token1计算最大流动性
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            pool.sqrtPriceX96(),
            sqrtRatioAX96Lower,
            sqrtRatioAX96Upper,
            params.amount0Desired,
            params.amount1Desired
        );

        // data 是 mint 后回调 PositionManager 会额外带的数据
        // 需要 PoistionManger 实现回调，在回调中给 Pool 打钱
        bytes memory data = abi.encode(
            params.token0,
            params.token1,
            params.index,
            msg.sender
        );
        // 基于这个流动性，创建头寸
        (uint256 amount0, uint256 amount1) = pool.mint(
            address(this),
            liquidity,
            data
        );
        // 调用 ERC721铸造NFT
        uint256 position = _nextId++;
        _mint(params.recipient, position);

        // 将头寸保存到本合约 positions 中
        (
            ,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            ,

        ) = pool.getPosition(address(this));

        positions[position] = PositionInfo({
            id: position,
            owner: params.recipient,
            token0: params.token0,
            token1: params.token1,
            index: params.index,
            fee: pool.fee(),
            liquidity: liquidity,
            tickLower: pool.tickLower(),
            tickUpper: pool.tickUpper(),
            tokensOwed0: 0,
            tokensOwed1: 0,
            // feeGrowthInside0LastX128 和 feeGrowthInside1LastX128 用于计算手续费
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128
        });
    }

    /**
     * 移除流动性
     * 返还token0,token1
     * 记录到头寸信息中
     * @param positionId 头寸id
     * @return amount0
     * @return amount1
     */
    function burn(
        uint256 positionId
    ) external returns (uint256 amount0, uint256 amount1) {
        PositionInfo storage positionInfo = positions[positionId];
        uint128 liquidity = positionInfo.liquidity;

        address poolAddress = poolManager.getPool(
            positionInfo.token0,
            positionInfo.token1,
            positionInfo.index
        );
        IPool pool = IPool(poolAddress);

        (uint256 amount0, uint256 amount1) = pool.burn(liquidity);

        // 计算这部分流动性产生的手续费
        (
            ,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            ,

        ) = pool.getPosition(address(this));

        // 返还的amount + 手续费
        positionInfo.tokensOwed0 +=
            uint128(amount0) +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 -
                        positionInfo.feeGrowthInside0LastX128,
                    positionInfo.liquidity,
                    FixedPoint128.Q128
                )
            );

        positionInfo.tokensOwed1 +=
            uint128(amount1) +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 -
                        positionInfo.feeGrowthInside1LastX128,
                    positionInfo.liquidity,
                    FixedPoint128.Q128
                )
            );
        // 更新手续费
        positionInfo.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        positionInfo.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
    }

    /**
     * 提取代币；销毁NFT
     * @param positionId 头寸id
     * @param recipient 提取地址
     * @return amount0
     * @return amount1
     */
    function collect(
        uint256 positionId,
        address recipient
    ) external returns (uint256 amount0, uint256 amount1) {
        PositionInfo storage positionInfo = positions[positionId];
        address poolAddress = poolManager.getPool(
            positionInfo.token0,
            positionInfo.token1,
            positionInfo.index
        );
        IPool pool = IPool(poolAddress);
        (amount0, amount1) = pool.collect(
            recipient,
            positionInfo.tokensOwed0,
            positionInfo.tokensOwed1
        );

        positionInfo.tokensOwed0 = 0;
        positionInfo.tokensOwed1 = 0;

        if (positionInfo.liquidity == 0) {
            _burn(positionId);
        }
    }

    /**
     * 调用pool.mint完成添加流动性后，pool合约回调该函数。
     * 将代币转到pool合约
     * @param amount0 token0数量
     * @param amount1 token1数量
     * @param data    本合约构造的回调参数
     */
    function mintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external {
        (address token0, address token1, uint32 index, address payer) = abi
            .decode(data, (address, address, uint32, address));

        address _pool = poolManager.getPool(token0, token1, index);
        require(_pool == msg.sender, "Invalid callback caller");

        IERC20(token0).transferFrom(payer, msg.sender, amount0);
        IERC20(token1).transferFrom(payer, msg.sender, amount1);
    }
}
