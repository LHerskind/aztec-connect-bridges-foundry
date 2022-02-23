// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "ds-test/test.sol";
import {Vm} from "../Vm.sol";

import {DefiBridgeProxy} from "aztec/DefiBridgeProxy.sol";
import {MockRollupProcessor} from "aztec/MockRollupProcessor.sol";

// Aave-specific imports
import {IWETH9} from "aave/interfaces/IWETH9.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Detailed} from "aave/interfaces/IERC20.sol";
import {ILendingPool} from "aave/interfaces/ILendingPool.sol";
import {ILendingPoolAddressesProvider} from "aave/interfaces/ILendingPoolAddressesProvider.sol";
import {IAaveIncentivesController} from "aave/interfaces/IAaveIncentivesController.sol";
import {IAToken} from "aave/interfaces/IAToken.sol";
import {AztecTypes} from "aztec/AztecTypes.sol";
import {WadRayMath} from "aave/libraries/WadRayMath.sol";
import {Errors} from "aave/libraries/Errors.sol";
import {AaveBorrowingBridge} from "aave/AaveBorrowing.sol";
import {AaveBorrowingBridgeProxy} from "aave/AaveBorrowingProxy.sol";

contract AaveBorrowingTest is DSTest {
    using WadRayMath for uint256;

    // Aztec defi bridge specific storage
    DefiBridgeProxy defiBridgeProxy;
    MockRollupProcessor rollupProcessor;

    AaveBorrowingBridge aaveBorrowingBridge;

    Vm VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    ILendingPoolAddressesProvider constant ADDRESSES_PROVIDER =
        ILendingPoolAddressesProvider(
            0xB53C1a33016B2DC2fF3653530bfF1848a515c8c5
        );

    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    ILendingPool pool = ILendingPool(ADDRESSES_PROVIDER.getLendingPool());

    function _aztecPreSetup() internal {
        defiBridgeProxy = new DefiBridgeProxy();
        rollupProcessor = new MockRollupProcessor(address(defiBridgeProxy));
    }

    function setUp() public {
        _aztecPreSetup();

        aaveBorrowingBridge = new AaveBorrowingBridge(
            address(rollupProcessor),
            address(ADDRESSES_PROVIDER)
        );
    }

    function testBorrowAndRepay() public {
        // TODO: We need some good test of the ratio stuff.
        // Ratio should be with same precision as collateral.
        // The ratio is essentially, how much debt per collateral token
        uint256 INITIAL_RATIO = 1000e18;
        uint256 id = aaveBorrowingBridge.deployProxy(
            address(WETH),
            address(DAI),
            INITIAL_RATIO
        );
        AaveBorrowingBridgeProxy proxy = AaveBorrowingBridgeProxy(
            aaveBorrowingBridge.proxies(id)
        );

        // Get some tokens
        _setTokenBalance(address(WETH), address(rollupProcessor), 100 ether);

        IERC20 accountingToken = proxy.accountingToken();

        // Do a deposit
        AztecTypes.AztecAsset memory emptyAsset = AztecTypes.AztecAsset({
            id: 0,
            erc20Address: address(0),
            assetType: AztecTypes.AztecAssetType.NOT_USED
        });
        AztecTypes.AztecAsset memory wethAsset = AztecTypes.AztecAsset({
            id: 1,
            erc20Address: address(WETH),
            assetType: AztecTypes.AztecAssetType.ERC20
        });
        AztecTypes.AztecAsset memory daiAsset = AztecTypes.AztecAsset({
            id: 2,
            erc20Address: address(DAI),
            assetType: AztecTypes.AztecAssetType.ERC20
        });
        AztecTypes.AztecAsset memory accountingAsset = AztecTypes.AztecAsset({
            id: 3,
            erc20Address: address(accountingToken),
            assetType: AztecTypes.AztecAssetType.ERC20
        });

        // TODO: need debt balances
        rollupProcessor.convert(
            address(aaveBorrowingBridge),
            wethAsset,
            emptyAsset,
            accountingAsset,
            daiAsset,
            100 ether,
            1,
            0
        );

        // do I have some dai
        emit log_named_decimal_uint(
            "Dai balance",
            DAI.balanceOf(address(rollupProcessor)),
            18
        );
        emit log_named_decimal_uint(
            "WETH balance",
            WETH.balanceOf(address(rollupProcessor)),
            18
        );
        emit log_named_decimal_uint(
            "Accounting balance",
            accountingToken.balanceOf(address(rollupProcessor)),
            18
        );

        emit log("Withdrawing 10 LP");
        rollupProcessor.convert(
            address(aaveBorrowingBridge),
            accountingAsset,
            emptyAsset,
            wethAsset,
            emptyAsset,
            10 ether,
            2,
            0
        );

        emit log_named_decimal_uint(
            "Dai balance",
            DAI.balanceOf(address(rollupProcessor)),
            18
        );
        emit log_named_decimal_uint(
            "WETH balance",
            WETH.balanceOf(address(rollupProcessor)),
            18
        );

        emit log_named_decimal_uint(
            "Accounting balance",
            accountingToken.balanceOf(address(rollupProcessor)),
            18
        );
    }

    function _setTokenBalance(
        address token,
        address user,
        uint256 balance
    ) internal {
        uint256 slot = 2;
        if (token == address(USDC)) {
            slot = 9;
        } else if (token == address(WBTC)) {
            slot = 0;
        } else if (token == address(WETH)) {
            slot = 3;
        }

        VM.store(
            token,
            keccak256(abi.encode(user, slot)),
            bytes32(uint256(balance))
        );

        assertEq(IERC20(token).balanceOf(user), balance, "wrong balance");
    }
}
