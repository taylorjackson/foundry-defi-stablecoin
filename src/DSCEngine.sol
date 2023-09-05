// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Taylor Jackson
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token to dollar peg.
 * It is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC.
 * @notice This contract is teh core of the DSC System.  It handles all of the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO system.
 */
contract DSCEngine is ReentrancyGuard {
    //////////////////////
    // Errors           //
    //////////////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorBelowThreshold(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOkay();
    error DSCEngine__HealthFactorNotImproved();

    //////////////////////
    // State Vars       //
    //////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinter) private s_dscMinted;
    address[] private s_collateralTokens;
    DecentralizedStableCoin private i_dsc;

    //////////////////////
    // Events           //
    //////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed ammount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 ammount
    );

    //////////////////////
    // Modifiers        //
    //////////////////////

    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    //////////////////////
    // Functions        //
    //////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            address tokenAddress = tokenAddresses[i];
            address priceFeedAddress = priceFeedAddresses[i];
            s_priceFeeds[tokenAddress] = priceFeedAddress;
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////
    // External Funcs   //
    //////////////////////

    /**
     *
     * @param tokenCollateralAddress The address of the token as collateral
     * @param amountCollateral The amount of collateral to be deposited.
     * @param amountDsc The amount of DSC to mint.
     * @notice this function will deposit your collateral and mint DSC in one transaction.
     */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDsc)
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDsc);
    }

    /**
     * @notice this function follows CEI
     * @param tokenCollateralAddress The address of the collateral token to be deposited.
     * @param amountCollateral The amount of collateral to be deposited.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of DSC to mint.
     * @notice they must have more collateral than the minumum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorBelowThreshold(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountDsc) public moreThanZero(amountDsc) nonReentrant {
        _burnDsc(amountDsc, msg.sender, msg.sender);
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this to work.
     * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOkay();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    ///////////////////////////////////////////
    // Private and Internal Functions        //
    ///////////////////////////////////////////

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalUsdMinted, uint256 collateralValueInUsd)
    {
        totalUsdMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @return How close the user is to being liquidated.
     */
    function _healthFactor(address user) internal view returns (uint256) {
        (uint256 totalUsdMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalUsdMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalUsdMinted;
    }

    function _revertIfHealthFactorBelowThreshold(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBelowThreshold(userHealthFactor);
        }
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dcsFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dcsFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amountDscToBurn);
    }

    ///////////////////////////////////////////
    // Public and External Functions        //
    ///////////////////////////////////////////

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];

            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }
}
