// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/Oracle.sol";

contract SomeOracle is Oracle, Ownable {
    mapping(string => uint) public prices;
    
    function price(string memory symbol) override public view returns (uint) {
        return prices[symbol];
    }

    function setPrice(string memory symbol, uint value) public onlyOwner {
        prices[symbol] = value;
    }
}
