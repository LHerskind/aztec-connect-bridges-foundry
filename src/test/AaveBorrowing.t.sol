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

contract AaveLendingTest is DSTest {
    using WadRayMath for uint256;

    Vm vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    ILendingPoolAddressesProvider constant addressesProvider =
        ILendingPoolAddressesProvider(
            0xB53C1a33016B2DC2fF3653530bfF1848a515c8c5
        );

    IERC20 constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    IPool pool = IPool(addressesProvider.getLendingPool());

    function setUp() public {}
}
