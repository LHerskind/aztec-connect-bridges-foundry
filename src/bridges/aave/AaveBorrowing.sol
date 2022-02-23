// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity >=0.6.10 <=0.8.10;
pragma experimental ABIEncoderV2;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IDefiBridge} from "../../interfaces/IDefiBridge.sol";
import {ILendingPoolAddressesProvider} from "./interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {IScaledBalanceToken} from "./interfaces/IScaledBalanceToken.sol";
import {IAaveIncentivesController} from "./interfaces/IAaveIncentivesController.sol";
import {IAccountingToken} from "./interfaces/IAccountingToken.sol";

import {IWETH9} from "./interfaces/IWETH9.sol";

import {AztecTypes} from "aztec/AztecTypes.sol";

import {AccountingToken} from "./AccountingToken.sol";
import {WadRayMath} from "./libraries/WadRayMath.sol";

import {DataTypes} from "./DataTypes.sol";
import {Errors} from "./libraries/Errors.sol";

import {AaveBorrowingBridgeProxy} from "./AaveBorrowingProxy.sol";

contract AaveBorrowingBridge is IDefiBridge, Ownable {
    using SafeMath for uint256;
    using WadRayMath for uint256;
    using SafeERC20 for IERC20;

    address public immutable ROLLUP_PROCESSOR;
    ILendingPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

    // TODO: Need access control for setting up stuff.

    IWETH9 public constant WETH =
        IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // index => proxy address
    mapping(uint256 => address) public proxies;
    uint256 public proxyCount;

    constructor(address _rollupProcessor, address _addressesProvider) {
        ROLLUP_PROCESSOR = _rollupProcessor;
        /// @dev addressesProvider is used to fetch pool, used in case Aave governance update pool proxy
        ADDRESSES_PROVIDER = ILendingPoolAddressesProvider(_addressesProvider);
    }

    function deployProxy(
        address _collateralAsset,
        address _borrowAsset,
        uint256 _initialRatio
    ) external onlyOwner returns (uint256) {
        // TODO: Can be made much more efficient with minimal proxies.
        uint256 proxyId = proxyCount++;
        proxies[proxyId] = address(
            new AaveBorrowingBridgeProxy(
                address(ADDRESSES_PROVIDER),
                _collateralAsset,
                _borrowAsset,
                _initialRatio
            )
        );
        return proxyId;
        // TODO: Emit some event
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
        AaveBorrowingBridgeProxy proxy = AaveBorrowingBridgeProxy(
            proxies[uint256(auxData)]
        );

        (
            address inputAsset,
            address collateralAsset,
            bool isEth
        ) = _sanityConvert(
                inputAssetA,
                inputAssetB,
                outputAssetA,
                outputAssetB,
                proxy
            );

        if (inputAsset == collateralAsset) {
            (outputValueA, outputValueB) = _enter(proxy, totalInputValue);
        } else {
            // input asset == accountAsset, ensured by _sanityConvert
            outputValueA = _exit(proxy, totalInputValue);
        }
    }

    function _enter(AaveBorrowingBridgeProxy proxy, uint256 collateralAmount)
        internal
        returns (uint256, uint256)
    {
        (
            uint256 lpTokenAmount,
            uint256 debtAmount,
            IERC20 lpToken,
            IERC20 collateralAsset,
            IERC20 borrowedAsset
        ) = proxy.enter(collateralAmount);

        ILendingPool pool = ILendingPool(ADDRESSES_PROVIDER.getLendingPool());

        collateralAsset.safeApprove(address(pool), collateralAmount);
        pool.deposit(
            address(collateralAsset),
            collateralAmount,
            address(proxy),
            0
        );

        pool.borrow(address(borrowedAsset), debtAmount, 2, 0, address(proxy));

        // Approve rollupProcessor to pull borrowed asset and lp tokens.
        borrowedAsset.safeApprove(ROLLUP_PROCESSOR, debtAmount);
        lpToken.safeApprove(ROLLUP_PROCESSOR, lpTokenAmount);

        return (lpTokenAmount, debtAmount);
    }

    function _exit(AaveBorrowingBridgeProxy proxy, uint256 lpAmount)
        internal
        returns (uint256)
    {
        (uint256 collateralAmount, IERC20 collateralAsset) = proxy.exit(
            lpAmount
        );

        collateralAsset.safeApprove(ROLLUP_PROCESSOR, collateralAmount);

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

    /**
     * @notice sanity checks from the sender and inputs to the convert function
     */
    function _sanityConvert(
        AztecTypes.AztecAsset memory inputAssetA,
        AztecTypes.AztecAsset memory inputAssetB,
        AztecTypes.AztecAsset memory outputAssetA,
        AztecTypes.AztecAsset memory outputAssetB,
        AaveBorrowingBridgeProxy proxy
    )
        internal
        view
        returns (
            address,
            address,
            bool
        )
    {
        require(msg.sender == ROLLUP_PROCESSOR, Errors.INVALID_CALLER);
        require(
            !(inputAssetA.assetType == AztecTypes.AztecAssetType.ETH &&
                outputAssetA.assetType == AztecTypes.AztecAssetType.ETH),
            Errors.INPUT_ASSET_A_AND_OUTPUT_ASSET_A_IS_ETH
        );
        // Check that input asset A type is valid
        require(
            inputAssetA.assetType == AztecTypes.AztecAssetType.ERC20 ||
                inputAssetA.assetType == AztecTypes.AztecAssetType.ETH,
            Errors.INPUT_ASSET_A_NOT_ERC20_OR_ETH
        );
        // Check that input asset B type is not used
        require(
            inputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED,
            Errors.INPUT_ASSET_B_NOT_EMPTY
        );
        // check that output asset A type is valid
        require(
            outputAssetA.assetType == AztecTypes.AztecAssetType.ERC20 ||
                outputAssetA.assetType == AztecTypes.AztecAssetType.ETH,
            Errors.OUTPUT_ASSET_A_NOT_ERC20_OR_ETH
        );
        require(
            outputAssetB.assetType == AztecTypes.AztecAssetType.ERC20 ||
                outputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED,
            "ERROR ON OUTPUT ASSET B TYPE"
        );

        (
            address collateralAsset,
            address debtAsset,
            address accountingAsset
        ) = proxy.getUnderlyings();

        address inputAsset = inputAssetA.assetType ==
            AztecTypes.AztecAssetType.ETH
            ? address(WETH)
            : inputAssetA.erc20Address;
        address oAssetA = outputAssetA.assetType ==
            AztecTypes.AztecAssetType.ETH
            ? address(WETH)
            : outputAssetA.erc20Address;

        require(
            inputAsset == collateralAsset || inputAsset == accountingAsset,
            "INVALID INPUT ASSET"
        );

        if (inputAsset == collateralAsset) {
            // Entering, check outputs
            require(
                oAssetA == accountingAsset,
                "OUTPUT ASSET A NOT ACCOUNTING ASSET"
            );
            require(
                outputAssetB.assetType == AztecTypes.AztecAssetType.ERC20,
                "OUTPUT ASSET B NOT ERC20"
            );
            require(
                outputAssetB.erc20Address == debtAsset,
                "OUTPUT ASSET B NOT DEBT ASSET"
            );
        }

        if (inputAsset == accountingAsset) {
            // Exiting, check outputs
            require(
                oAssetA == collateralAsset,
                "OUTPUT ASSET A NOT COLLATERAL ASSET"
            );
            require(
                outputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED,
                Errors.OUTPUT_ASSET_B_NOT_EMPTY
            );
        }

        bool isEth = inputAssetA.assetType == AztecTypes.AztecAssetType.ETH ||
            outputAssetA.assetType == AztecTypes.AztecAssetType.ETH;

        return (inputAsset, collateralAsset, isEth);
    }
}
