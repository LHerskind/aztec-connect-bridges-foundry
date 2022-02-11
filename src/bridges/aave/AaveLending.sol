// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity >=0.6.10 <=0.8.10;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IRollupProcessor} from "../../interfaces/IRollupProcessor.sol";

import {IDefiBridge} from "../../interfaces/IDefiBridge.sol";
import {ILendingPoolAddressesProvider} from "./interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IScaledBalanceToken} from "./interfaces/IScaledBalanceToken.sol";
import {IAaveIncentivesController} from "./interfaces/IAaveIncentivesController.sol";
import {IAccountingToken} from "./interfaces/IAccountingToken.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

import {AztecTypes} from "../../aztec/AztecTypes.sol";

import {AccountingToken} from "./AccountingToken.sol";
import {WadRayMath} from "./libraries/WadRayMath.sol";

import {DataTypes} from "./DataTypes.sol";
import {Errors} from "./libraries/Errors.sol";

contract AaveLendingBridge is IDefiBridge {
    using SafeMath for uint256;
    using WadRayMath for uint256;
    using SafeERC20 for IERC20;

    IWETH9 public constant WETH =
        IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address public immutable rollupProcessor;
    ILendingPoolAddressesProvider public immutable addressesProvider;
    address public immutable rewardsBeneficiary;

    /// Mapping underlying assets to the zk atoken used for accounting
    mapping(address => address) public underlyingToZkAToken;
    mapping(address => address) public underlyingToAToken;

    receive() external payable {}

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

        ILendingPool pool = ILendingPool(addressesProvider.getLendingPool());

        // TODO: Issue, this is not compatible with Aave V3 return value.
        IERC20Metadata aToken = IERC20Metadata(
            pool.getReserveData(underlyingAsset).aTokenAddress
        );

        require(address(aToken) != address(0), Errors.INVALID_ATOKEN);

        string memory name = string(abi.encodePacked("ZK-", aToken.name()));
        string memory symbol = string(abi.encodePacked("ZK-", aToken.symbol()));

        underlyingToZkAToken[underlyingAsset] = address(
            new AccountingToken(name, symbol, aToken.decimals())
        );
        underlyingToAToken[underlyingAsset] = address(aToken);
    }

    /**
     * @notice sanity checks from the sender and inputs to the convert function
     */
    function _sanityConvert(
        AztecTypes.AztecAsset memory inputAssetA,
        AztecTypes.AztecAsset memory inputAssetB,
        AztecTypes.AztecAsset memory outputAssetA,
        AztecTypes.AztecAsset memory outputAssetB
    )
        public
        view
        returns (
            address inputAsset,
            address outputAsset,
            bool isEth
        )
    {
        require(msg.sender == rollupProcessor, Errors.INVALID_CALLER);
        require(
            !(inputAssetA.assetType == AztecTypes.AztecAssetType.ETH &&
                outputAssetA.assetType == AztecTypes.AztecAssetType.ETH),
            "Cannot use eth as input AND output"
        );
        require(
            inputAssetA.assetType == AztecTypes.AztecAssetType.ERC20 ||
                inputAssetA.assetType == AztecTypes.AztecAssetType.ETH,
            Errors.INPUT_ASSET_A_NOT_ERC20
        );
        require(
            outputAssetA.assetType == AztecTypes.AztecAssetType.ERC20 ||
                outputAssetA.assetType == AztecTypes.AztecAssetType.ETH,
            Errors.OUTPUT_ASSET_A_NOT_ERC20
        );
        require(
            inputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED,
            Errors.INPUT_ASSET_B_NOT_EMPTY
        );
        require(
            outputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED,
            Errors.OUTPUT_ASSET_B_NOT_EMPTY
        );

        if (inputAssetA.assetType == AztecTypes.AztecAssetType.ETH) {
            inputAsset = address(WETH);
            outputAsset = outputAssetA.erc20Address;
            isEth = true;
        } else if (outputAssetA.assetType == AztecTypes.AztecAssetType.ETH) {
            inputAsset = inputAssetA.erc20Address;
            outputAsset = address(WETH);
            isEth = true;
        } else {
            inputAsset = inputAssetA.erc20Address;
            outputAsset = outputAssetA.erc20Address;
        }
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
        (address inputAsset, address outputAsset, bool isEth) = _sanityConvert(
            inputAssetA,
            inputAssetB,
            outputAssetA,
            outputAssetB
        );

        address zkAToken = underlyingToZkAToken[inputAsset];

        if (zkAToken == address(0)) {
            /// The `inputAssetA.erc20Address` must be a zk-asset (or unsupported asset).
            /// The `outputAssetA.erc20Address` will then be the underlying asset
            /// Entering with zkAsset and leaving with underlying is exiting
            outputValueA = _exit(
                outputAsset,
                totalInputValue,
                interactionNonce,
                isEth
            );
        } else {
            /// The `zkAToken` exists, the input must be a supported underlying.
            /// Enter with the underlying.
            outputValueA = _enter(inputAsset, totalInputValue, isEth);
        }
    }

    /**
     * @notice Deposit into Aave with `amount` of `underlyingAsset` and return the corresponding amount of zkATokens
     * @param underlyingAsset The address of the underlying asset
     * @param amount The amount of underlying asset to deposit
     * @return The amount of zkAToken that was minted by the deposit
     */
    function _enter(
        address underlyingAsset,
        uint256 amount,
        bool isEth
    ) internal returns (uint256) {
        if (isEth) {
            WETH.deposit{value: amount}();
        }
        ILendingPool pool = ILendingPool(addressesProvider.getLendingPool());

        IScaledBalanceToken aToken = IScaledBalanceToken(
            underlyingToAToken[underlyingAsset]
        );

        require(address(aToken) != address(0), Errors.INVALID_ATOKEN);
        IAccountingToken zkAToken = IAccountingToken(
            underlyingToZkAToken[underlyingAsset]
        );
        require(address(zkAToken) != address(0), Errors.ZK_TOKEN_DONT_EXISTS);

        // 1. Read the scaled balance from the lending pool
        uint256 scaledBalance = aToken.scaledBalanceOf(address(this));

        // 2. Approve totalInputValue to be lent on AAVE
        IERC20(underlyingAsset).safeIncreaseAllowance(address(pool), amount);

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
    function _exit(
        address underlyingAsset,
        uint256 scaledAmount,
        uint256 interactionNonce,
        bool isEth
    ) internal returns (uint256) {
        ILendingPool pool = ILendingPool(addressesProvider.getLendingPool());

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

        // 3. Burn the supplied amount of zkAToken as this has now been withdrawn
        IAccountingToken(underlyingToZkAToken[underlyingAsset]).burn(
            scaledAmount
        );

        if (isEth) {
            WETH.withdraw(outputValue);
            IRollupProcessor(rollupProcessor).receiveEthFromBridge{
                value: outputValue
            }(interactionNonce);
        } else {
            // 4. Approve rollup to spend underlying
            IERC20(underlyingAsset).safeIncreaseAllowance(
                rollupProcessor,
                outputValue
            );
        }

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