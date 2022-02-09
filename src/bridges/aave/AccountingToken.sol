// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2022 Spilsbury Holdings Ltd
pragma solidity >=0.6.10 <=0.8.10;
pragma experimental ABIEncoderV2;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IAccountingToken} from "./interfaces/IAccountingToken.sol";

contract AccountingToken is IAccountingToken, ERC20Burnable {
    address public immutable owner;
    uint8 internal immutable tokenDecimals;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) ERC20(_name, _symbol) {
        owner = msg.sender;
        tokenDecimals = _decimals;
    }

    function decimals()
        public
        view
        virtual
        override(IERC20Metadata, ERC20)
        returns (uint8)
    {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount)
        external
        override(IAccountingToken)
    {
        require(owner == msg.sender, "Caller not owner");
        _mint(to, amount);
    }

    function burn(uint256 amount)
        public
        virtual
        override(IAccountingToken, ERC20Burnable)
    {
        super.burn(amount);
    }
}
