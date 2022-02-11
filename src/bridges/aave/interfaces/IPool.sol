// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.10;

import {DataTypes} from "../DataTypes.sol";

interface IPool {
    function getReserveData(address asset)
        external
        view
        returns (DataTypes.ReserveDataV3 memory);
}
