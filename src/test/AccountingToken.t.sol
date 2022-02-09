// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "ds-test/test.sol";

import {AccountingToken} from "./../bridges/aave/AccountingToken.sol";
import {Vm} from "./Vm.sol";

contract AccountingTokenTest is DSTest {
    Vm vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    AccountingToken token;

    function setUp() public {
        token = new AccountingToken("Test", "Test", 18);
    }

    function testDecimals(uint8 _decimals) public {
        AccountingToken temp = new AccountingToken("Test", "Test", _decimals);
        assertEq(temp.decimals(), _decimals, "Decimals not matching");
    }

    function testOwnerMinting(uint256 _amount) public {
        token.mint(address(this), _amount);
        assertEq(token.totalSupply(), _amount, "Total supply not matching");
        assertEq(
            token.balanceOf(address(this)),
            _amount,
            "Balance not matching"
        );
    }

    function testNonOwnerMinting(uint256 _amount) public {
        vm.startPrank(address(0x1));

        vm.expectRevert("Caller not owner");
        token.mint(address(this), _amount);

        assertEq(token.totalSupply(), 0, "Total supply not matching");
        assertEq(token.balanceOf(address(this)), 0, "Balance not matching");
    }

    function testBurnOwnToken(uint256 _amount) public {
        address user = address(0x1);

        token.mint(user, _amount);

        assertEq(token.totalSupply(), _amount, "Total supply not matching");
        assertEq(token.balanceOf(user), _amount, "Balance not matching");

        vm.startPrank(user);
        token.burn(_amount);

        assertEq(token.totalSupply(), 0, "Total supply not matching");
        assertEq(token.balanceOf(user), 0, "Balance not matching");
    }

    function testBurnOtherUsersToken(uint256 _amount) public {
        address user1 = address(0x1);
        address user2 = address(0x2);

        token.mint(user1, _amount);

        assertEq(token.totalSupply(), _amount, "Total supply not matching");
        assertEq(token.balanceOf(user1), _amount, "Balance not matching");

        vm.startPrank(user2);
        vm.expectRevert("ERC20: burn amount exceeds allowance");
        token.burnFrom(user1, _amount);

        assertEq(token.totalSupply(), _amount, "Total supply not matching");
        assertEq(token.balanceOf(user1), _amount, "Balance not matching");
    }
}
