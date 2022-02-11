// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity >=0.6.10 <=0.8.10;
pragma experimental ABIEncoderV2;

import {TokenTransfers} from "./../../libraries/TokenTransfers.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IDefiBridge} from "../../interfaces/IDefiBridge.sol";
import {ILendingPoolAddressesProvider} from "./interfaces/ILendingPoolAddressesProvider.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IScaledBalanceToken} from "./interfaces/IScaledBalanceToken.sol";
import {ICreditDelegationToken} from "./interfaces/ICreditDelegationToken.sol";
import {IAaveIncentivesController} from "./interfaces/IAaveIncentivesController.sol";
import {IAccountingToken} from "./interfaces/IAccountingToken.sol";

import {AztecTypes} from "../../aztec/AztecTypes.sol";

import {AccountingToken} from "./AccountingToken.sol";
import {WadRayMath} from "./libraries/WadRayMath.sol";

import {DataTypes} from "./DataTypes.sol";
import {Errors} from "./libraries/Errors.sol";

contract AaveBorrowingBridgeProxy {
    address public immutable borrowingBridge;
    ILendingPoolAddressesProvider public immutable addressesProvider;

    IERC20Metadata public immutable aToken;
    IERC20 public immutable debtToken;
    IERC20 public immutable collateralUnderlying;
    IERC20 public immutable debtUnderlying;
    uint256 public immutable collateralPrecision;
    uint256 public immutable initialRatio;
    AccountingToken public immutable accountingToken;

    modifier onlyBorrowingBridge() {
        require(msg.sender == borrowingBridge, "Caller not borrowing bridge");
        _;
    }

    constructor(
        address _addressesProvider,
        address _collateralToken,
        address _borrowToken,
        uint256 _initialRatio
    ) {
        borrowingBridge = msg.sender;
        addressesProvider = ILendingPoolAddressesProvider(_addressesProvider);

        IPool pool = IPool(
            ILendingPoolAddressesProvider(_addressesProvider).getLendingPool()
        );

        collateralUnderlying = IERC20(_collateralToken);
        debtUnderlying = IERC20(_borrowToken);

        aToken = IERC20Metadata(
            pool.getReserveData(_collateralToken).aTokenAddress
        );
        address variableDebtTokenAddress = pool
            .getReserveData(_borrowToken)
            .variableDebtTokenAddress;

        debtToken = IERC20(variableDebtTokenAddress);
        ICreditDelegationToken(variableDebtTokenAddress).approveDelegation(
            msg.sender,
            type(uint256).max
        );

        initialRatio = _initialRatio;

        uint256 collateralDecimals = aToken.decimals();
        collateralPrecision = 10**collateralDecimals;

        accountingToken = new AccountingToken(
            "NAME",
            "NAME",
            uint8(collateralDecimals)
        );
    }

    function getStats()
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 collateralBalance = aToken.balanceOf(address(this));
        if (collateralBalance == 0) {
            return (0, 0, 0);
        }
        uint256 debtBalance = debtToken.balanceOf(address(this));
        uint256 ratio = (debtBalance * collateralPrecision) / collateralBalance;
        return (collateralBalance, debtBalance, ratio);
    }

    function enter(uint256 collateralAmount)
        external
        onlyBorrowingBridge
        returns (
            uint256,
            uint256,
            IERC20,
            IERC20,
            IERC20
        )
    {
        (
            uint256 collateralBalance,
            uint256 debtBalance,
            uint256 ratio
        ) = getStats();

        uint256 lpTokenAmount;
        uint256 debtAmount;

        if (ratio == 0) {
            lpTokenAmount = collateralAmount;
            debtAmount =
                (collateralAmount * initialRatio) /
                collateralPrecision;
        } else {
            lpTokenAmount =
                (collateralAmount * collateralPrecision) /
                collateralBalance;
            debtAmount = (collateralAmount * ratio) / collateralPrecision;
        }

        accountingToken.mint(msg.sender, lpTokenAmount);

        return (
            lpTokenAmount,
            debtAmount,
            IERC20(address(accountingToken)),
            collateralUnderlying,
            debtUnderlying
        );
    }

    function exit(uint256 lpAmount)
        external
        onlyBorrowingBridge
        returns (uint256, IERC20)
    {
        uint256 supply = accountingToken.totalSupply();
        (
            uint256 collateralBalance,
            uint256 debtBalance,
            uint256 ratio
        ) = getStats();

        uint256 debtAmount = (debtBalance * lpAmount) / supply;
        uint256 collateralAmount = (collateralBalance * lpAmount) / supply;

        accountingToken.burn(msg.sender, lpAmount);

        // Repay with collateral - maybe we could just use the paraswap stuff directly?
        // 1. Borrow debtAmount of debtToken with a flashloan
        // 2. Repay debtAmount of debtToken
        // 3. Withdraw collateralAmount of collateral
        // 4. Swap some collateral to debt token
        // 5. Repay flashloan
        // 6. Transfer excess collateral to borrowing bridge

        // paraswap?? https://github.com/paraswap/aave-protocol-v2/blob/feature/paraswap-repay/contracts/adapters/ParaSwapRepayAdapter.sol

        // Gas-wise it seems absolute shit. 
        // Expecting that we could probably get around it just with some uniswap V3? Possible even just using V3 liquidity.

        // need to do a safe transfer and return the value
        // safeTransferTo()
        // return amount

        return (0, collateralUnderlying);
    }

    function _repayWithCollateral() internal {}

    // TODO: Make a test where we are doing the paraswap stuff, seems like something that is a lot easier to test if it works before we build all the other stuff out. 
}
