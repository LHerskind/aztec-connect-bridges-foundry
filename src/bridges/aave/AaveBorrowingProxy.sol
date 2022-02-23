// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "ds-test/test.sol";

import {TokenTransfers} from "./../../libraries/TokenTransfers.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IDefiBridge} from "../../interfaces/IDefiBridge.sol";
import {ILendingPoolAddressesProvider} from "./interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {IScaledBalanceToken} from "./interfaces/IScaledBalanceToken.sol";
import {ICreditDelegationToken} from "./interfaces/ICreditDelegationToken.sol";
import {IAaveIncentivesController} from "./interfaces/IAaveIncentivesController.sol";
import {IAccountingToken} from "./interfaces/IAccountingToken.sol";
import {IPriceOracleGetter} from "./interfaces/IPriceOracleGetter.sol";

import {AztecTypes} from "../../aztec/AztecTypes.sol";

import {AccountingToken} from "./AccountingToken.sol";
import {WadRayMath} from "./libraries/WadRayMath.sol";

import {DataTypes} from "./DataTypes.sol";
import {Errors} from "./libraries/Errors.sol";

import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";

contract AaveBorrowingBridgeProxy is DSTest {
    address public immutable borrowingBridge;
    ILendingPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;

    IERC20Metadata public immutable aToken;
    IERC20Metadata public immutable debtToken;
    IERC20 public immutable collateralUnderlying;
    IERC20 public immutable debtUnderlying;
    uint256 public immutable collateralPrecision;
    uint256 public immutable debtPrecision;
    uint256 public immutable INITIAL_RATIO;
    AccountingToken public immutable accountingToken;

    modifier onlyBorrowingBridge() {
        require(msg.sender == borrowingBridge, "Caller not borrowing bridge");
        _;
    }

    function getUnderlyings()
        public
        view
        returns (
            address,
            address,
            address
        )
    {
        return (
            address(collateralUnderlying),
            address(debtUnderlying),
            address(accountingToken)
        );
    }

    constructor(
        address _addressesProvider,
        address _collateralToken,
        address _borrowToken,
        uint256 _initialRatio
    ) {
        borrowingBridge = msg.sender;
        ADDRESSES_PROVIDER = ILendingPoolAddressesProvider(_addressesProvider);

        ILendingPool pool = ILendingPool(
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

        debtToken = IERC20Metadata(variableDebtTokenAddress);
        ICreditDelegationToken(variableDebtTokenAddress).approveDelegation(
            msg.sender,
            type(uint256).max
        );

        debtPrecision = 10**debtToken.decimals();

        uint256 collateralDecimals = aToken.decimals();
        collateralPrecision = 10**collateralDecimals;

        accountingToken = new AccountingToken(
            "NAME",
            "NAME",
            uint8(collateralDecimals)
        );

        INITIAL_RATIO = _initialRatio;
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
            return (0, 0, INITIAL_RATIO);
        }
        uint256 debtBalance = debtToken.balanceOf(address(this));
        uint256 ratio = (debtBalance * collateralPrecision) / collateralBalance;
        return (collateralBalance, debtBalance, ratio);
    }

    function enter(uint256 amount)
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

        if (collateralBalance == 0) {
            lpTokenAmount = amount;
        } else {
            lpTokenAmount = (amount * collateralPrecision) / collateralBalance;
        }
        debtAmount = (amount * ratio) / collateralPrecision;

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

        bytes memory params = abi.encode(collateralAmount);

        ILendingPool pool = ILendingPool(ADDRESSES_PROVIDER.getLendingPool());

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes = new uint256[](1);

        assets[0] = address(debtUnderlying);
        amounts[0] = debtAmount;
        modes[0] = 2;

        pool.flashLoan(
            address(this),
            assets,
            amounts,
            modes,
            address(this),
            params,
            0
        );

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

        // TODO, can be optimized heavily if using uniswap flashswaps directly instead of this

        uint256 collateralLeft = collateralUnderlying.balanceOf(address(this));
        collateralUnderlying.safeTransfer(msg.sender, collateralLeft);

        return (collateralLeft, collateralUnderlying);
    }

    /// To handle flashloans from Aave
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(initiator == address(this), Errors.INVALID_CALLER); // TODO: Better error msg
        require(
            assets.length * amounts.length * premiums.length == 1,
            "Mismatch in lengths"
        );

        ILendingPool pool = ILendingPool(ADDRESSES_PROVIDER.getLendingPool());
        IPriceOracleGetter oracle = IPriceOracleGetter(
            ADDRESSES_PROVIDER.getPriceOracle()
        );

        // Approve the lendingpool for amounts[0] * 2 + premiums[0]
        // amounts[0] to repay original debt
        // amounts[0] + premiums[0] to repay flashloan
        debtUnderlying.safeApprove(address(pool), amounts[0] * 2 + premiums[0]);

        // Repay some debt
        pool.repay(address(debtUnderlying), amounts[0], 2, address(this));

        // Withdraw some collateral
        uint256 collateralAmount = abi.decode(params, (uint256));
        pool.withdraw(
            address(collateralUnderlying),
            collateralAmount,
            address(this)
        );

        uint256 collateralAssetPrice = oracle.getAssetPrice(
            address(collateralUnderlying)
        );
        uint256 debtAssetPrice = oracle.getAssetPrice(address(debtUnderlying));

        // Compute the max amount collateral to swap with 5% slippage
        uint256 flashLoanDebt = amounts[0] + premiums[0];
        uint256 maxCollateralSwapped = (flashLoanDebt *
            debtAssetPrice *
            collateralPrecision) / (collateralAssetPrice * debtPrecision);
        maxCollateralSwapped = (maxCollateralSwapped * 10000) / 9750;
        // We are doing less here than we should Probably the opposite way we should to it. So max is larger

        // TODO: We could handoff this swapping to some other contract, and then simply be using the  computation so some other contract. And then do approvals before and after and checking that the values match something we have expected? Seems like a better solution to have it more future ready

        address swapperAddress = address(
            0xf164fC0Ec4E93095b804a4795bBe1e041497b92a
        );
        collateralUnderlying.safeApprove(swapperAddress, maxCollateralSwapped);

        // TODO: Create paths, If one of the tokens is weth, only 2, otherwise length 3
        address[] memory path = new address[](2);
        // TODO: For now assume direct
        path[0] = address(collateralUnderlying);
        path[1] = address(debtUnderlying);

        // I'm fogetting to insert the amount I want xD idiot

        uint256[] memory amounts = IUniswapV2Router02(swapperAddress)
            .swapTokensForExactTokens(
                flashLoanDebt,
                maxCollateralSwapped,
                path,
                address(this),
                block.timestamp
            );

        collateralUnderlying.safeApprove(swapperAddress, 0);

        uint256 minLeft = collateralAmount - maxCollateralSwapped;
        require(
            collateralUnderlying.balanceOf(address(this)) >= minLeft,
            "Unsatisfying swap"
        );
        // Note: No need to check if we got the correct token back from the swap. The clawback will fail if not.
        // And the contract should not contain any plain funds by itself.

        return true;
    }
}
