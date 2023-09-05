// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Decentralized Stable Coin
 * @author Taylor Jackson
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: 1 USD
 *
 * This is the contract meant to be governed by DSCEngine.  This contract is the ERC20
 * implementation of our stablecoin system.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    function burn(uint256 amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }

        if (balance < amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }

        super.burn(amount);
    }

    function mint(address _to, uint256 amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }

        if (amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }

        _mint(_to, amount);
        return true;
    }
}
