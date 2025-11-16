// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "./interfaces/IFactory.sol";

contract Factory is IFactory {
    // 交易池
    mapping(address token0 => mapping(address token1 => address[] pool))
        public pools;

    Parameters public parameters;

    function sort(
        address tokenA,
        address tokenB
    ) public pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function getPool(
        address tokenA,
        address tokenB,
        uint32 index
    ) external view override returns (address pool) {
        (address token0, address token1) = sort(tokenA, tokenB);
        return pools[token0][token1][index];
    }

    function createPool(
        address tokenA,
        address tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint24 fee
    ) external override returns (address pool) {}

    constructor() {}
}
