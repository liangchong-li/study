// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "./Factory.sol";
import "./interfaces/IPoolManager.sol";
import "./interfaces/IPool.sol";

/**
 * @title 交易池管理。与前端交互
 */
contract PoolManager is Factory, IPoolManager {
    Pair[] public pairs;

    // 获取所有交易对
    function getPairs() external view override returns (Pair[] memory) {
        return pairs;
    }

    // 获取所有交易池
    function getAllPools()
        external
        view
        override
        returns (PoolInfo[] memory poolsInfo)
    {
        // 计算长度
        uint256 length;
        for (uint i = 0; i < pairs.length; i++) {
            length += pools[pairs[i].token0][pairs[i].token1].length;
        }

        // 固定长度
        poolsInfo = new PoolInfo[](length);
        uint256 index = 0;
        for (uint i = 0; i < pairs.length; i++) {
            address[] memory poolArray = pools[pairs[i].token0][
                pairs[i].token1
            ];
            for (uint32 j = 0; j < poolArray.length; j++) {
                IPool pool = IPool(poolArray[j]);
                poolsInfo[index] = PoolInfo({
                    pool: poolArray[j],
                    token0: pool.token0(),
                    token1: pool.token1(),
                    index: j,
                    fee: pool.fee(),
                    feeProtocol: 0,
                    tickLower: pool.tickLower(),
                    tickUpper: pool.tickUpper(),
                    tick: pool.tick(),
                    sqrtPriceX96: pool.sqrtPriceX96(),
                    liquidity: pool.liquidity()
                });
            }
        }
    }

    // 创建交易池
    function createAndInitializePoolIfNecessary(
        CreateAndInitializeParams calldata params
    ) external payable override returns (address poolAddress) {
        // 不存在则创建
        require(
            params.token0 < params.token1,
            "token0 must be less than token1"
        );

        // 调用 factory 合约的创建方法
        poolAddress = this.createPool(
            params.token0,
            params.token1,
            params.tickLower,
            params.tickUpper,
            params.fee
        );

        // 调用pool 的initialize 方法 初始化价格
        IPool pool = IPool(poolAddress);
        if (pool.sqrtPriceX96() == 0) {
            pool.initialize(params.sqrtPriceX96);
            // 如果交易对不存在，则创建交易对
            if (pools[pool.token0()][pool.token1()].length == 1) {
                pairs.push(
                    Pair({token0: pool.token0(), token1: pool.token1()})
                );
            }
        }
    }
}
