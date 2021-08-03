// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";
import "../interfaces/ICToken.sol";

library CompoundLib {

    using SafeCast for uint256;
    using SafeMath for uint256;

    struct Adapters {
        ICToken ctoken;
    }

    /// @dev Balance in Compound, in Dai (might spend gas)
    function balanceOf(Adapters memory adapter, address who) internal returns (uint256) {
        return adapter.ctoken.balanceOf(who).mul(CDaiToDai(adapter));
    }
  
    /// @dev Brings Dai to Exactly
    function withdraw(Adapters memory adapter, uint256 amountDai) internal {
        require(adapter.ctoken.redeemUnderlying(amountDai) == 0, "COMPOUND: withdraw failed");
    }

    /// @dev Brings Dai to Exactly
    function deposit(Adapters memory adapter, uint256 amountDai) internal {
        require(adapter.ctoken.mint(amountDai) == 0, "COMPOUND: supply failed");
    }

    /// @dev How much is worth one of our cTokens in DAI
    function CDaiToDai(Adapters memory adapter) internal returns (uint256) { 
        return adapter.ctoken.exchangeRateCurrent().div(1e18);
    }
}