// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity >=0.6.10 <=0.8.10;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IDefiBridge} from "../../interfaces/IDefiBridge.sol";
import {ILendingPoolAddressesProvider} from "./interfaces/ILendingPoolAddressesProvider.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IScaledBalanceToken} from "./interfaces/IScaledBalanceToken.sol";
import {IAaveIncentivesController} from "./interfaces/IAaveIncentivesController.sol";
import {IAccountingToken} from "./interfaces/IAccountingToken.sol";

import {AztecTypes} from "../../aztec/AztecTypes.sol";

import {AccountingToken} from "./AccountingToken.sol";
import {WadRayMath} from "./libraries/WadRayMath.sol";

import {DataTypes} from "./DataTypes.sol";
import {Errors} from "./libraries/Errors.sol";

import {AaveBorrowingBridgeProxy} from "./AaveBorrowingProxy.sol";

contract AaveBorrowingBridge is IDefiBridge {
    using SafeMath for uint256;
    using WadRayMath for uint256;

    address public immutable rollupProcessor;
    ILendingPoolAddressesProvider public immutable addressesProvider;

    // index => proxy address
    mapping(uint256 => address) public proxies;
    uint256 public proxyCount;

    constructor(address _rollupProcessor, address _addressesProvider) {
        rollupProcessor = _rollupProcessor;
        /// @dev addressesProvider is used to fetch pool, used in case Aave governance update pool proxy
        addressesProvider = ILendingPoolAddressesProvider(_addressesProvider);
    }

    function deployProxy(
        address _collateralAsset,
        address _borrowAsset,
        uint256 _initialRatio
    ) external {
        uint256 proxyId = proxyCount++;
        proxies[proxyId] = address(
            new AaveBorrowingBridgeProxy(
                address(addressesProvider),
                _collateralAsset,
                _borrowAsset,
                _initialRatio
            )
        );
        // TODO: Emit some event
    }

    /**
     * @notice sanity checks from the sender and inputs to the convert function
     */
    function _sanityCheckConvert(
        AztecTypes.AztecAsset memory inputAssetA,
        AztecTypes.AztecAsset memory inputAssetB,
        AztecTypes.AztecAsset memory outputAssetA,
        AztecTypes.AztecAsset memory outputAssetB
    ) public view {
        require(msg.sender == rollupProcessor, Errors.INVALID_CALLER);
        require(
            inputAssetA.assetType == AztecTypes.AztecAssetType.ERC20,
            Errors.INPUT_ASSET_A_NOT_ERC20
        );
        require(
            inputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED,
            Errors.INPUT_ASSET_B_NOT_EMPTY
        );
        require(
            outputAssetA.assetType == AztecTypes.AztecAssetType.ERC20,
            Errors.OUTPUT_ASSET_A_NOT_ERC20
        );
        require(
            outputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED,
            Errors.OUTPUT_ASSET_B_NOT_EMPTY
        );
    }

    function convert(
        AztecTypes.AztecAsset memory inputAssetA,
        AztecTypes.AztecAsset memory inputAssetB,
        AztecTypes.AztecAsset memory outputAssetA,
        AztecTypes.AztecAsset memory outputAssetB,
        uint256 totalInputValue,
        uint256 interactionNonce,
        uint64 auxData // Use this as the index.
    )
        external
        payable
        override
        returns (
            uint256 outputValueA,
            uint256 outputValueB,
            bool isAsync
        )
    {
        _sanityCheckConvert(
            inputAssetA,
            inputAssetB,
            outputAssetA,
            outputAssetB
        );

        /*        address zkAToken = underlyingToZkAToken[inputAssetA.erc20Address];

        if (zkAToken == address(0)) {
            /// The `inputAssetA.erc20Address` must be a zk-asset (or unsupported asset).
            /// The `outputAssetA.erc20Address` will then be the underlying asset
            /// Entering with zkAsset and leaving with underlying is exiting
            outputValueA = _exit(outputAssetA.erc20Address, totalInputValue);
        } else {
            /// The `zkAToken` exists, the input must be a supported underlying.
            /// Enter with the underlying.
            outputValueA = _enter(inputAssetA.erc20Address, totalInputValue);
        }*/
    }

    function _enter(uint256 index, uint256 collateralAmount)
        internal
        returns (uint256, uint256)
    {
        AaveBorrowingBridgeProxy proxy = AaveBorrowingBridgeProxy(
            proxies[index]
        );

        (
            uint256 lpTokenAmount,
            uint256 debtAmount,
            IERC20 lpToken,
            IERC20 collateralAsset,
            IERC20 borrowedAsset
        ) = proxy.enter(collateralAmount);

        IPool pool = IPool(addressesProvider.getLendingPool());

        collateralAsset.safeIncreaseAllowance(address(pool), collateralAmount);
        pool.deposit(
            address(collateralAsset),
            collateralAmount,
            address(proxy),
            0
        );

        pool.borrow(address(borrowedAsset), debtAmount, 2, 0, address(proxy));

        // TODO: Need to use safeApprove as USDT is non-standard! Not sure if people would borrow, but if they are going to it will mess us up.

        // Approve rollupProcessor to pull borrowed asset and lp tokens.
        borrowedAsset.safeIncreaseAllowance(rollupProcessor, debtAmount);
        lpToken.safeIncreaseAllowance(rollupProcessor, lpTokenAmount);

        return (lpTokenAmount, debtAmount);
    }

    function _exit(uint256 index, uint256 lpAmount) internal returns (uint256) {
        AaveBorrowingBridgeProxy proxy = AaveBorrowingBridgeProxy(
            proxies[index]
        );
        (uint256 collateralAmount, IERC20 collateralAsset) = proxy.exit(
            lpAmount
        );

        collateralAsset.safeIncreaseAllowance(
            address(rollupProcessor, collateralAmount)
        );

        return collateralAmount;
    }

    function canFinalise(
        uint256 /*interactionNonce*/
    ) external view override returns (bool) {
        return false;
    }

    function finalise(
        AztecTypes.AztecAsset calldata inputAssetA,
        AztecTypes.AztecAsset calldata inputAssetB,
        AztecTypes.AztecAsset calldata outputAssetA,
        AztecTypes.AztecAsset calldata outputAssetB,
        uint256 interactionNonce,
        uint64 auxData
    ) external payable override returns (uint256, uint256) {
        require(false);
    }
}
