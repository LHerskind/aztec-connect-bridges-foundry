// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity 0.8.10;

import {ILendingPoolAddressesProvider} from "./ILendingPoolAddressesProvider.sol";

interface IAaveLendingBridge {
    function setUnderlyingToZkAToken(
        address underlyingAsset,
        address aTokenAddress
    ) external;

    function claimLiquidityRewards(
        address incentivesController,
        address[] calldata assets
    ) external returns (uint256);

    function ROLLUP_PROCESSOR() external view returns (address);

    function ADDRESSES_PROVIDER()
        external
        view
        returns (ILendingPoolAddressesProvider);

    function REWARDS_BENEFICIARY() external view returns (address);

    function CONFIGURATOR() external view returns (address);

    /// Mapping underlying assets to the zk atoken used for accounting
    function underlyingToZkAToken(address underlyingAsset)
        external
        view
        returns (address);

    function underlyingToAToken(address underlyingAsset)
        external
        view
        returns (address);
}
