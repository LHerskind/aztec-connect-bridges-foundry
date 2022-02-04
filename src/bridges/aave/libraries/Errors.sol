// SPDX-License-Identifier: GPL-2.0-only
pragma solidity >=0.6.10 <=0.8.10;

library Errors {
    string internal constant INVALID_CALLER = "1";
    string internal constant INPUT_ASSET_A_NOT_ERC20 = "2";
    string internal constant INPUT_ASSET_B_NOT_EMPTY = "3";
    string internal constant OUTPUT_ASSET_A_NOT_ERC20 = "4";
    string internal constant OUTPUT_ASSET_B_NOT_EMPTY = "5";
    string internal constant INVALID_ATOKEN = "6";
    string internal constant ZK_TOKEN_ALREADY_SET = "7";
    string internal constant ZK_TOKEN_DONT_EXISTS = "8";
}
