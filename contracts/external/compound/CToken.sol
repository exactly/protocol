// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../../interfaces/ICToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CToken is ICToken, ERC20 {
    constructor (string memory name_, string memory symbol_) ERC20 (name_, symbol_) {}

    function exchangeRateCurrent() external override returns (uint256) {
        return 
    }

    function supplyRatePerBlock() external override returns (uint256) {
        return 100;
    }
    
    function redeem(uint) external override returns (uint) {

    }
    function redeemUnderlying(uint) external override returns (uint) {

    }

}