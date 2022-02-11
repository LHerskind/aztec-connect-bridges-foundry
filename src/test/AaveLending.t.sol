// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "ds-test/test.sol";
import {Vm} from "./Vm.sol";

import {DefiBridgeProxy} from "./../aztec/DefiBridgeProxy.sol";
import {MockRollupProcessor} from "./../aztec/MockRollupProcessor.sol";

// Aave-specific imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Detailed} from "./../bridges/aave/interfaces/IERC20.sol";
import {AaveLendingBridge} from "./../bridges/aave/AaveLending.sol";
import {IPool} from "./../bridges/aave/interfaces/IPool.sol";
import {ILendingPoolAddressesProvider} from "./../bridges/aave/interfaces/ILendingPoolAddressesProvider.sol";
import {IAaveIncentivesController} from "./../bridges/aave/interfaces/IAaveIncentivesController.sol";
import {IAToken} from "./../bridges/aave/interfaces/IAToken.sol";
import {AztecTypes} from "./../aztec/AztecTypes.sol";
import {WadRayMath} from "./../bridges/aave/libraries/WadRayMath.sol";
import {Errors} from "./../bridges/aave/libraries/Errors.sol";

import {DataTypes} from "./../bridges/aave/DataTypes.sol";

contract AaveLendingTest is DSTest {
    using WadRayMath for uint256;

    Vm vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // TODO: Must check using both USDT, WETH etc

    DefiBridgeProxy defiBridgeProxy;
    MockRollupProcessor rollupProcessor;

    AaveLendingBridge aaveLendingBridge;
    ILendingPoolAddressesProvider constant addressesProvider =
        ILendingPoolAddressesProvider(
            0xB53C1a33016B2DC2fF3653530bfF1848a515c8c5
        );
    IERC20 constant stkAave =
        IERC20(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    IPool pool = IPool(addressesProvider.getLendingPool());

    address constant beneficiary = address(0xbe);

    IAaveIncentivesController constant incentives =
        IAaveIncentivesController(0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5);

    IERC20 token;
    IAToken aToken;

    // divisor and minValue is used to constrain deposit value to not be too large or too small.
    // minimum 1 whole token, maximum (2**128-1) / (10**(18 - aToken.decimals()))
    uint256 internal divisor;
    uint256 internal minValue;

    IERC20 constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 constant usdt = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant wbtc = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    IERC20[] tokens = [dai, usdt, usdc, wbtc];

    function _aztecPreSetup() internal {
        defiBridgeProxy = new DefiBridgeProxy();
        rollupProcessor = new MockRollupProcessor(address(defiBridgeProxy));
    }

    function _tokenSetup(IERC20 _token) internal {
        token = _token;
        DataTypes.ReserveData memory data = pool.getReserveData(address(token));
        aToken = IAToken(pool.getReserveData(address(token)).aTokenAddress);
        minValue = 10**aToken.decimals();
        divisor = 10**(18 - aToken.decimals());
    }

    function setUp() public {
        _aztecPreSetup();
        _tokenSetup(usdc);

        aaveLendingBridge = new AaveLendingBridge(
            address(rollupProcessor),
            address(addressesProvider),
            beneficiary
        );
    }

    function testAddTokensToMapping() public {
        for (uint256 i = 0; i < tokens.length; i++) {
            _tokenSetup(tokens[i]);
            emit log(aToken.name());
            _addTokenToMapping();
        }
    }

    function testZKATokenNaming() public {
        for (uint256 i = 0; i < tokens.length; i++) {
            _tokenSetup(tokens[i]);
            _ZKATokenNaming();
        }
    }

    function _addTokenToMapping() public {
        assertEq(
            aaveLendingBridge.underlyingToZkAToken(address(token)),
            address(0)
        );

        /// Add invalid (revert)
        vm.expectRevert(bytes(Errors.INVALID_ATOKEN));
        aaveLendingBridge.setUnderlyingToZkAToken(address(0xdead));

        /// Add token
        aaveLendingBridge.setUnderlyingToZkAToken(address(token));
        assertNotEq(
            aaveLendingBridge.underlyingToZkAToken(address(token)),
            address(0)
        );

        /// Add token again (revert)
        vm.expectRevert(bytes(Errors.ZK_TOKEN_ALREADY_SET));
        aaveLendingBridge.setUnderlyingToZkAToken(address(token));
    }

    function _ZKATokenNaming() public {
        _setupToken();
        IERC20Detailed zkToken = IERC20Detailed(
            aaveLendingBridge.underlyingToZkAToken(address(token))
        );

        string memory name = string(abi.encodePacked("ZK-", aToken.name()));
        string memory symbol = string(abi.encodePacked("ZK-", aToken.symbol()));

        assertEq(
            zkToken.symbol(),
            symbol,
            "The zkAToken token symbol don't match"
        );
        assertEq(zkToken.name(), name, "The zkAToken token name don't match");
        assertEq(
            zkToken.decimals(),
            aToken.decimals(),
            "The zkAToken token decimals don't match"
        );
    }

    function testFailEnterWithToken() public {
        _setupToken();
        _enterWithToken(0);
    }

    function testEnterWithTokenBigValues() public {
        _setupToken();
        _enterWithToken(type(uint128).max);
    }

    function testFailExitPartially() public {
        _setupToken();
        _enterWithToken(100 ether / divisor);
        _accrueInterest(60 * 60 * 24);
        _exitWithToken(0);
    }

    function testEnterWithToken(uint128 depositAmount, uint16 timeDiff) public {
        for (uint256 i = 0; i < tokens.length; i++) {
            _tokenSetup(tokens[i]);
            _setupToken();
            _enterWithToken(max(depositAmount / divisor, minValue));
            _accrueInterest(timeDiff);
        }
    }

    function testAdditionalEnter(
        uint128 depositAmount1,
        uint128 depositAmount2,
        uint16 timeDiff
    ) public {
        for (uint256 i = 0; i < tokens.length; i++) {
            _tokenSetup(tokens[i]);
            _setupToken();
            _enterWithToken(max(depositAmount1 / divisor, minValue));
            _accrueInterest(timeDiff);
            _enterWithToken(max(depositAmount2 / divisor, minValue));
        }
    }

    function testExitPartially(
        uint128 depositAmount,
        uint128 withdrawAmount,
        uint16 timeDiff
    ) public {
        for (uint256 i = 0; i < tokens.length; i++) {
            _tokenSetup(tokens[i]);

            uint256 depositAmount = max(depositAmount / divisor, minValue);
            uint256 index = pool.getReserveNormalizedIncome(address(token));
            uint256 scaledDepositAmount = uint256(depositAmount).rayDiv(index);

            _setupToken();
            _enterWithToken(depositAmount);
            _accrueInterest(timeDiff);

            withdrawAmount = uint128(
                min(withdrawAmount, scaledDepositAmount / 2)
            );

            _exitWithToken(withdrawAmount);
        }
    }

    function testExitPartiallyThenCompletely(
        uint128 depositAmount,
        uint16 timeDiff1,
        uint16 timeDiff2
    ) public {
        for (uint256 i = 0; i < tokens.length; i++) {
            _tokenSetup(tokens[i]);

            uint256 depositAmount = max(depositAmount / divisor, minValue);

            _setupToken();
            _enterWithToken(depositAmount);

            _accrueInterest(timeDiff1);

            _exitWithToken(depositAmount / 2);

            Balances memory balances = _getBalances();

            _accrueInterest(timeDiff2);

            _exitWithToken(balances.rollupZk);

            Balances memory balancesAfter = _getBalances();

            assertLt(
                balances.rollupZk,
                depositAmount,
                "never entered, or entered at index = 1"
            );
            assertEq(balancesAfter.rollupZk, 0, "Not exited with everything");
        }
    }

    function testExitCompletely(uint128 depositAmount, uint16 timeDiff) public {
        for (uint256 i = 0; i < tokens.length; i++) {
            _tokenSetup(tokens[i]);

            _setupToken();
            uint256 depositAmount = max(depositAmount / divisor, minValue);

            _enterWithToken(depositAmount);

            Balances memory balances = _getBalances();

            _accrueInterest(timeDiff + 1); // Ensure that some time have passed

            _exitWithToken(balances.rollupZk);

            Balances memory balancesAfter = _getBalances();

            assertLt(
                balances.rollupZk,
                depositAmount,
                "entered at index = 1 RAY with and no interest accrual"
            );
            assertEq(balancesAfter.rollupZk, 0, "Not exited with everything");
        }
    }

    function testClaimRewards(uint128 depositAmount, uint16 timeDiff) public {
        for (uint256 i = 0; i < tokens.length; i++) {
            _tokenSetup(tokens[i]);

            _setupToken();
            _enterWithToken(max(depositAmount / divisor, minValue));
            _accrueInterest(timeDiff);

            address[] memory assets = new address[](1);
            assets[0] = address(aToken);

            assertEq(
                stkAave.balanceOf(address(aaveLendingBridge)),
                0,
                "Already have reward tokens"
            );

            uint256 expectedRewards = aaveLendingBridge.claimLiquidityRewards(
                address(incentives),
                assets
            );

            // The claiming of liquidity rewards is not always returning the actual value increase
            assertCloseTo(
                stkAave.balanceOf(address(aaveLendingBridge)),
                expectedRewards,
                2
            );
        }
    }

    /// Helpers

    function assertNotEq(address a, address b) internal {
        if (a == b) {
            emit log("Error: a != b not satisfied [address]");
            emit log_named_address("  Expected", b);
            emit log_named_address("    Actual", a);
            fail();
        }
    }

    function assertCloseTo(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal {
        uint256 diff = a > b ? a - b : b - a;
        if (diff > c) {
            emit log("Error: a close to b not satisfied [uint256]");
            emit log_named_uint(" Expected", b);
            emit log_named_uint("   Actual", a);
        }
    }

    function _setupToken() internal {
        aaveLendingBridge.setUnderlyingToZkAToken(address(token));
    }

    function _setTokenBalance(
        address token,
        address user,
        uint256 balance
    ) internal {
        uint256 slot = 2;
        if (token == address(usdc)) {
            slot = 9;
        } else if (token == address(wbtc)) {
            slot = 0;
        }

        vm.store(
            token,
            keccak256(abi.encode(user, slot)),
            bytes32(uint256(balance))
        );

        assertEq(IERC20(token).balanceOf(user), balance, "wrong balance");
    }

    struct Balances {
        uint256 rollupToken;
        uint256 rollupZk;
        uint256 bridgeAToken;
        uint256 bridgeScaledAToken;
    }

    function _getBalances() internal view returns (Balances memory) {
        IERC20 zkToken = IERC20(
            aaveLendingBridge.underlyingToZkAToken(address(token))
        );
        address rp = address(rollupProcessor);
        address dbp = address(aaveLendingBridge);
        return
            Balances({
                rollupToken: token.balanceOf(rp),
                rollupZk: zkToken.balanceOf(rp),
                bridgeAToken: aToken.balanceOf(dbp),
                bridgeScaledAToken: aToken.scaledBalanceOf(dbp)
            });
    }

    function _accrueInterest(uint256 timeDiff) internal {
        // Will increase time with at least 24 hours to ensure that interest accrued is not rounded down.
        timeDiff = timeDiff + 60 * 60 * 24;

        Balances memory balancesBefore = _getBalances();
        uint256 expectedTokenBefore = balancesBefore.rollupZk.rayMul(
            pool.getReserveNormalizedIncome(address(token))
        );

        vm.warp(block.timestamp + timeDiff);

        Balances memory balancesAfter = _getBalances();
        uint256 expectedTokenAfter = balancesAfter.rollupZk.rayMul(
            pool.getReserveNormalizedIncome(address(token))
        );

        if (timeDiff > 0) {
            assertGt(
                expectedTokenAfter,
                expectedTokenBefore,
                "Did not earn any interest"
            );
        }

        assertEq(
            expectedTokenBefore,
            balancesBefore.bridgeAToken,
            "Bridge aToken not matching before time"
        );
        assertEq(
            expectedTokenAfter,
            balancesAfter.bridgeAToken,
            "Bridge aToken not matching after time"
        );
    }

    function _enterWithToken(uint256 amount) public {
        IERC20 zkAToken = IERC20(
            aaveLendingBridge.underlyingToZkAToken(address(token))
        );

        uint256 depositAmount = amount;
        _setTokenBalance(
            address(token),
            address(rollupProcessor),
            depositAmount
        );

        Balances memory balanceBefore = _getBalances();

        AztecTypes.AztecAsset memory empty;
        AztecTypes.AztecAsset memory inputAsset = AztecTypes.AztecAsset({
            id: 1,
            erc20Address: address(token),
            assetType: AztecTypes.AztecAssetType.ERC20
        });
        AztecTypes.AztecAsset memory outputAsset = AztecTypes.AztecAsset({
            id: 2,
            erc20Address: address(zkAToken),
            assetType: AztecTypes.AztecAssetType.ERC20
        });

        (
            uint256 outputValueA,
            uint256 outputValueB,
            bool isAsync
        ) = rollupProcessor.convert(
                address(aaveLendingBridge),
                inputAsset,
                empty,
                outputAsset,
                empty,
                depositAmount,
                1,
                0
            );

        Balances memory balanceAfter = _getBalances();

        uint256 index = pool.getReserveNormalizedIncome(address(token));
        uint256 scaledDiff = depositAmount.rayDiv(index);
        uint256 expectedScaledBalanceAfter = balanceBefore.rollupZk +
            scaledDiff;
        uint256 expectedATokenBalanceAfter = expectedScaledBalanceAfter.rayMul(
            index
        );

        assertEq(
            balanceBefore.rollupZk,
            balanceBefore.bridgeScaledAToken,
            "Scaled balances before not matching"
        );
        assertEq(
            balanceAfter.rollupZk,
            balanceAfter.bridgeScaledAToken,
            "Scaled balances after not matching"
        );
        assertEq(
            balanceAfter.rollupZk - balanceBefore.rollupZk,
            outputValueA,
            "Output value and zk balance not matching"
        );
        assertEq(
            balanceAfter.rollupZk - balanceBefore.rollupZk,
            scaledDiff,
            "Scaled balance change not matching"
        );
        assertEq(
            expectedATokenBalanceAfter,
            balanceAfter.bridgeAToken,
            "aToken balance not matching"
        );
        assertEq(
            balanceBefore.rollupToken - balanceAfter.rollupToken,
            depositAmount,
            "Bridge token not matching"
        );
    }

    function _exitWithToken(uint256 zkAmount) public {
        IERC20 zkAToken = IERC20(
            aaveLendingBridge.underlyingToZkAToken(address(token))
        );

        uint256 withdrawAmount = zkAmount;

        Balances memory balanceBefore = _getBalances();

        AztecTypes.AztecAsset memory empty;
        AztecTypes.AztecAsset memory inputAsset = AztecTypes.AztecAsset({
            id: 2,
            erc20Address: address(zkAToken),
            assetType: AztecTypes.AztecAssetType.ERC20
        });
        AztecTypes.AztecAsset memory outputAsset = AztecTypes.AztecAsset({
            id: 1,
            erc20Address: address(token),
            assetType: AztecTypes.AztecAssetType.ERC20
        });

        (
            uint256 outputValueA,
            uint256 outputValueB,
            bool isAsync
        ) = rollupProcessor.convert(
                address(aaveLendingBridge),
                inputAsset,
                empty,
                outputAsset,
                empty,
                withdrawAmount,
                2,
                0
            );

        Balances memory balanceAfter = _getBalances();

        uint256 index = pool.getReserveNormalizedIncome(address(token));
        uint256 innerATokenWithdraw = withdrawAmount.rayMul(index);
        uint256 innerScaledChange = innerATokenWithdraw.rayDiv(index);

        // This will fail if the zkAmount > balance of zkATokens
        assertEq(withdrawAmount, innerScaledChange, "Inner not matching");

        uint256 expectedScaledBalanceAfter = balanceBefore.rollupZk -
            withdrawAmount;
        uint256 expectedATokenBalanceAfter = expectedScaledBalanceAfter.rayMul(
            index
        );

        assertEq(
            innerATokenWithdraw,
            outputValueA,
            "Output token does not match expected output"
        );
        assertEq(
            balanceBefore.rollupZk,
            balanceBefore.bridgeScaledAToken,
            "Scaled balance before not matching"
        );
        assertEq(
            balanceAfter.rollupZk,
            balanceAfter.bridgeScaledAToken,
            "Scaled balance after not matching"
        );
        assertEq(
            balanceAfter.rollupZk,
            expectedScaledBalanceAfter,
            "Scaled balance after not matching"
        );
        assertEq(
            balanceBefore.rollupZk - balanceAfter.rollupZk,
            withdrawAmount,
            "Change in zk balance is equal to deposit amount"
        );
        assertEq(
            balanceAfter.bridgeAToken,
            expectedATokenBalanceAfter,
            "Bridge aToken balance don't match expected"
        );
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
