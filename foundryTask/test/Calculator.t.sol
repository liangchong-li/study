// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Calculator} from "../src/Calculator.sol";

contract CalculatorTest is Test {
    Calculator public calc;

    function setUp() public {
        calc = new Calculator();
    }

    function test_Add() public view {
        int256 res = calc.add(1, 2);
        assertEq(res, 3);
    }

    // 模糊测试
    function testFuzz_Add(int256 a, int256 b) public view {
        // 避免算术溢出
        a = bound(a, type(int128).min, type(int128).max);
        b = bound(b, type(int128).min, type(int128).max);
        // 执行加法
        int256 result = calc.add(a, b);

        // 验证结果正确性
        assertEq(result, a + b);
    }

    function test_Sub() public view {
        int256 res = calc.sub(1, 2);
        assertEq(res, -1);
    }

    // 模糊测试
    function testFuzz_Sub(int256 a, int256 b) public view {
        // 避免算术溢出
        a = bound(a, type(int128).min, type(int128).max);
        b = bound(b, type(int128).min, type(int128).max);
        // 执行加法
        int256 result = calc.sub(a, b);

        // 验证结果正确性
        assertEq(result, a - b);
    }
}
