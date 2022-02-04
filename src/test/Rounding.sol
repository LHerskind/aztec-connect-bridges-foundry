// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "ds-test/test.sol";

import {WadRayMath} from "./../bridges/aave/libraries/WadRayMath.sol";

contract RoundingTest is DSTest {
    using WadRayMath for uint256;

    function testRounding(uint128 amountIn, uint128 indexAdd) public {
        uint256 scaledAmount = amountIn; // using uint128 to not run into overflow
        uint256 index = 1e27 + indexAdd;

        uint256 intermediateVal = scaledAmount.rayMul(index);
        uint256 output = intermediateVal.rayDiv(index);

        assertEq(
            scaledAmount,
            output,
            "Scaled amounts don't match due to rounding issues"
        );
    }
}
