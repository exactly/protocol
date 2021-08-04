// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../../interfaces/ICToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CToken is ICToken, ERC20 {
    constructor (string memory name_, string memory symbol_) ERC20 (name_, symbol_) {}

    function exchangeRateCurrent() external override returns (uint256) {
        return 1.2 * 10e18;
    }

    function supplyRatePerBlock() external override returns (uint256) {
        return 100;
    }
    
    function redeem(uint amount) external override returns (uint) {
        return 100;
    }

    function redeemUnderlying(uint amount) external override returns (uint) {
        return 100;
    }

    function mint(uint256 amount) external override returns (uint256) {
        super.mint(amount);
    }
}