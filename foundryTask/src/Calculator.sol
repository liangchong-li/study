// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

/**
 * @title 包含基本算术运算（如加法、减法）的智能合约
 * @author
 * @notice
 */
contract Calculator {
    function add(int256 a, int256 b) public pure returns (int256 res) {
        // return a + b;
        assembly {
            res := add(a, b)
        }
    }

    function sub(int256 a, int256 b) public pure returns (int256 res) {
        // return a - b;
        assembly {
            res := sub(a, b)
        }
    }
}
