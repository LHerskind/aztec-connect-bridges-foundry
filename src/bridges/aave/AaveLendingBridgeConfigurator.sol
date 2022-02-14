// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity 0.8.10;
pragma experimental ABIEncoderV2;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAaveLendingBridgeConfigurator} from "./interfaces/IAaveLendingBridgeConfigurator.sol";
import {IAaveLendingBridge} from "./interfaces/IAaveLendingBridge.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {IPool} from "./interfaces/IPool.sol";

contract AaveLendingBridgeConfigurator is
    IAaveLendingBridgeConfigurator,
    Ownable
{
    function addNewPool(
        address lendingBridge,
        address underlyingAsset,
        address aTokenAddress
    ) public override(IAaveLendingBridgeConfigurator) onlyOwner {
        IAaveLendingBridge(lendingBridge).setUnderlyingToZkAToken(
            underlyingAsset,
            aTokenAddress
        );
    }

    function addPoolFromV2(address lendingBridge, address underlyingAsset)
        external
        override(IAaveLendingBridgeConfigurator)
        onlyOwner
    {
        IAaveLendingBridge bridge = IAaveLendingBridge(lendingBridge);
        ILendingPool pool = ILendingPool(
            bridge.addressesProvider().getLendingPool()
        );

        address aTokenAddress = pool
            .getReserveData(underlyingAsset)
            .aTokenAddress;

        addNewPool(lendingBridge, underlyingAsset, aTokenAddress);
    }

    function addPoolFromV3(address lendingBridge, address underlyingAsset)
        external
        override(IAaveLendingBridgeConfigurator)
        onlyOwner
    {
        IAaveLendingBridge bridge = IAaveLendingBridge(lendingBridge);
        IPool pool = IPool(bridge.addressesProvider().getLendingPool());

        address aTokenAddress = pool
            .getReserveData(underlyingAsset)
            .aTokenAddress;

        addNewPool(lendingBridge, underlyingAsset, aTokenAddress);
    }
}
