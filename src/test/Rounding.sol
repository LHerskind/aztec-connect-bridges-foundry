// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "ds-test/test.sol";

import {WadRayMath} from "./../bridges/aave/libraries/WadRayMath.sol";

contract RoundingTest is DSTest {
    using WadRayMath for uint256;

    function testRounding(uint128 amountIn, uint104 indexAdd) public {
        uint256 scaledAmount = uint256(amountIn); // using uint128 to not run into overflow
        uint256 index = uint256(1e27) + uint256(indexAdd);

        uint256 intermediateVal = scaledAmount.rayMul(index);
        uint256 output = intermediateVal.rayDiv(index);

        assertEq(
            scaledAmount,
            output,
            "Scaled amounts don't match due to rounding issues"
        );
    }
}
