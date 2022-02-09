// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity >=0.6.10 <=0.8.10;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
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

contract AaveLendingBridge is IDefiBridge {
    using SafeMath for uint256;
    using WadRayMath for uint256;

    address public immutable rollupProcessor;
    ILendingPoolAddressesProvider public immutable addressesProvider;
    address public immutable rewardsBeneficiary;

    /// Mapping underlying assets to the zk atoken used for accounting
    mapping(address => address) public underlyingToZkAToken;

    constructor(
        address _rollupProcessor,
        address _addressesProvider,
        address _rewardsBeneficiary
    ) public {
        rollupProcessor = _rollupProcessor;
        /// @dev addressesProvider is used to fetch pool, used in case Aave governance update pool proxy
        addressesProvider = ILendingPoolAddressesProvider(_addressesProvider);
        rewardsBeneficiary = _rewardsBeneficiary;
    }

    /**
     * @notice Add the underlying asset to the set of supported assets
     * @dev For the underlying to be accepted, the asset must be supported in Aave
     * @dev Underlying assets that already is supported cannot be added again.
     */
    function setUnderlyingToZkAToken(address underlyingAsset) external {
        require(
            underlyingToZkAToken[underlyingAsset] == address(0),
            Errors.ZK_TOKEN_ALREADY_SET
        );

        IPool pool = IPool(addressesProvider.getLendingPool());

        IERC20Metadata aToken = IERC20Metadata(
            pool.getReserveData(underlyingAsset).aTokenAddress
        );

        require(address(aToken) != address(0), Errors.INVALID_ATOKEN);

        string memory name = string(abi.encodePacked("ZK-", aToken.name()));
        string memory symbol = string(abi.encodePacked("ZK-", aToken.symbol()));

        underlyingToZkAToken[underlyingAsset] = address(
            new AccountingToken(name, symbol, aToken.decimals())
        );
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
        uint64 auxData
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

        address zkAToken = underlyingToZkAToken[inputAssetA.erc20Address];

        if (zkAToken == address(0)) {
            /// The `inputAssetA.erc20Address` must be a zk-asset (or unsupported asset).
            /// The `outputAssetA.erc20Address` will then be the underlying asset
            /// Entering with zkAsset and leaving with underlying is exiting
            outputValueA = _exit(outputAssetA.erc20Address, totalInputValue);
        } else {
            /// The `zkAToken` exists, the input must be a supported underlying.
            /// Enter with the underlying.
            outputValueA = _enter(inputAssetA.erc20Address, totalInputValue);
        }
    }

    /**
     * @notice Deposit into Aave with `amount` of `underlyingAsset` and return the corresponding amount of zkATokens
     * @param underlyingAsset The address of the underlying asset
     * @param amount The amount of underlying asset to deposit
     * @return The amount of zkAToken that was minted by the deposit
     */
    function _enter(address underlyingAsset, uint256 amount)
        internal
        returns (uint256)
    {
        IPool pool = IPool(addressesProvider.getLendingPool());
        IScaledBalanceToken aToken = IScaledBalanceToken(
            pool.getReserveData(underlyingAsset).aTokenAddress
        );
        require(address(aToken) != address(0), Errors.INVALID_ATOKEN);
        IAccountingToken zkAToken = IAccountingToken(
            underlyingToZkAToken[underlyingAsset]
        );
        require(address(zkAToken) != address(0), Errors.ZK_TOKEN_DONT_EXISTS);

        // 1. Read the scaled balance from the lending pool
        uint256 scaledBalance = aToken.scaledBalanceOf(address(this));

        // 2. Approve totalInputValue to be lent on AAVE
        IERC20(underlyingAsset).approve(address(pool), amount);

        // 3. Lend totalInputValue of inputAssetA on AAVE lending pool
        pool.deposit(underlyingAsset, amount, address(this), 0);

        // 4. Mint the difference between the scaled balance at the start of the interaction and after the deposit as our zkAToken
        uint256 diff = aToken.scaledBalanceOf(address(this)).sub(scaledBalance);
        zkAToken.mint(address(this), diff);

        // 5. Approve processor to pull zk aTokens.
        zkAToken.approve(rollupProcessor, diff);
        return diff;
    }

    /**
     * @notice Withdraw `underlyingAsset` from Aave
     * @param underlyingAsset The address of the underlying asset
     * @param scaledAmount The amount of zkAToken to burn, used to derive underlying amount
     * @return The underlying amount of tokens withdrawn
     */
    function _exit(address underlyingAsset, uint256 scaledAmount)
        internal
        returns (uint256)
    {
        IPool pool = IPool(addressesProvider.getLendingPool());

        // 1. Compute the amount from the scaledAmount supplied
        uint256 underlyingAmount = scaledAmount.rayMul(
            pool.getReserveNormalizedIncome(underlyingAsset)
        );

        // 2. Lend totalInputValue of inputAssetA on AAVE lending pool and return the amount of tokens
        uint256 outputValue = pool.withdraw(
            underlyingAsset,
            underlyingAmount,
            address(this)
        );

        // 3. Approve rollup to spend underlying
        IERC20(underlyingAsset).approve(rollupProcessor, outputValue);

        // 4. Burn the supplied amount of zkAToken as this has now been withdrawn
        IAccountingToken(underlyingToZkAToken[underlyingAsset]).burn(
            scaledAmount
        );

        return outputValue;
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
     * @notice Claim liquidity mining rewards and transfer to the beneficiary
     */
    function claimLiquidityRewards(
        address incentivesController,
        address[] calldata assets
    ) external returns (uint256) {
        // Just to have an initial claim rewards function
        // Don't like that we are accepting any contract from the users. Not obvious how they would abuse though.
        // Assets are approved to the lendingPool, but it does not have a claimRewards function that can be abused.
        // The malicious controller can be used to reenter. But limited what can be entered again as convert can only be entered by the processor.
        // To limit attack surface. Can pull incentives controller from assets and ensure that the assets are actually supported assets.
        IAaveIncentivesController controller = IAaveIncentivesController(
            incentivesController
        );
        return
            controller.claimRewards(
                assets,
                type(uint256).max,
                rewardsBeneficiary
            );
    }
}
