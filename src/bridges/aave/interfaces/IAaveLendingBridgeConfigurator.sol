// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity 0.8.10;

interface IAaveLendingBridgeConfigurator {
    function addNewPool(
        address lendingBridge,
        address underlyingAsset,
        address aTokenAddress
    ) external;

    function addPoolFromV2(address lendingBridge, address underlyingAsset)
        external;

    function addPoolFromV3(address lendingBridge, address underlyingAsset)
        external;
}
