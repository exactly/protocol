// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";

struct Double {
    uint256 value;
}

library DecimalMath {

    uint256 private constant NUMBER_SCALE = 1e18;
    uint256 private constant DOUBLE_SCALE = 1e36;

    function mul_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b / NUMBER_SCALE;
    }

    function mul_(uint256 a, uint256 b, uint256 scale) internal pure returns (uint256) {
        return a * b / scale;
    }

    function div_(uint256 a, uint256 b, uint256 scale) internal pure returns (uint256) {
        return a * scale / b;
    }

    function div_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * NUMBER_SCALE / b;
    }

    function div_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({value: a.value * DOUBLE_SCALE / b.value});
    }

    function mul_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({value: a.value * b.value / DOUBLE_SCALE});
    }

    function mul_(uint a, Double memory b) internal pure returns (uint) {
        return a * b.value / DOUBLE_SCALE;
    }

    function add_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({value: a.value + b.value});
    }

    function sub_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({value: a.value - b.value});
    }

    function fraction(uint a, uint b) internal pure returns (Double memory) {
        return Double({value: (a * DOUBLE_SCALE / b)});
    }

    // @notice Converts an amount of a particular token into a normalized USD value
    // @dev it abstracts the decimals of the token, it's used to compute liquidity
    // @param tokenAmount the amount of the token to convert to USD
    // @param oraclePrice the price of the token, as returned from the oracle
    // @param underlyingDecimals the decimals of the token (eg: 18 instead of 10**18)
    // @return the amount of USD the asset represents, normalized to 18 decimals precision
    function getTokenAmountInUSD(uint256 tokenAmount, uint256 oraclePrice, uint8 underlyingDecimals) internal pure returns (uint256){
      uint256 tokenScale = 10**underlyingDecimals;
      uint256 normalizedTokenAmount = tokenAmount* NUMBER_SCALE / tokenScale;
      return normalizedTokenAmount*oraclePrice/NUMBER_SCALE;
    }

    // @notice Converts normalized USD value into an  amount of a particular token
    // @dev it abstracts the decimals of the token, it's used to get the seizable amount in a liquidation
    // @param usdAmount the amount of usd to convert to the token
    // @param oraclePrice the price of the token, as returned from the oracle
    // @param tokenDecimals the decimals of the token (eg: 18 instead of 10**18)
    // @return the raw amount of the token equivalent to the provided usd amount
    function getTokenAmountFromUsd(uint256 usdAmount, uint256 oraclePrice, uint8 tokenDecimals) internal pure returns(uint256) {
        return ((usdAmount * NUMBER_SCALE/oraclePrice)*10**tokenDecimals)/ NUMBER_SCALE;
    }
}
