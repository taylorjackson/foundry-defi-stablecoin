// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;

    address public USER = address(1);
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = config.activeNetworkConfig();

        if (block.chainid == 31337) {
            vm.deal(USER, STARTING_USER_BALANCE);
        }

        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_USER_BALANCE);
    }

    ////////////////////////////
    // Price Feeds            //
    ////////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 30000e18;
        uint256 expectedEthAmount = 15e18;
        uint256 actualEthAmount = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedEthAmount, actualEthAmount);
    }

    ////////////////////////////
    // Constructor            //
    ////////////////////////////

    function testReverIfTokenLenghDoesntMatchPriceFeeds() public {
        address[] memory tokens = new address[](1);
        address[] memory priceFeeds = new address[](2);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokens, priceFeeds, address(dsc));
    }

    /////////////////////////////////
    // depositCollateral Tests     //
    /////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock mock = new ERC20Mock("Mock", "Mock", address(this), 1000e18);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.depositCollateral(address(mock), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 debt, uint256 collateralInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedCollateralAmountAmount = dsce.getTokenAmountFromUsd(weth, collateralInUsd);
        assertEq(AMOUNT_COLLATERAL, expectedCollateralAmountAmount);
        assertEq(debt, 0);
    }

    /////////////////////////////////
    // mint/burn DSC Tests         //
    /////////////////////////////////

    function testCanMintDscAfterUseDepositsCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(100);
        assertEq(dsc.balanceOf(USER), 100);
        vm.stopPrank();
    }

    function testCanBurnDscAfterUseDepositsCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(100);
        ERC20(dsc).approve(address(dsce), 100);
        assertEq(dsc.balanceOf(USER), 100);
        dsce.burnDsc(50);
        assertEq(dsc.balanceOf(USER), 50);
        vm.stopPrank();
    }
}
