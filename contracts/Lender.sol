//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";

contract Lender is Ownable {

    using SafeMath for uint256;

    event NewContribution(address indexed lender, uint amount);
    event NewExtraction(address indexed lender, uint amount);

    mapping (address => uint) loans;
    mapping (address => uint) moneyPool;

    function pool(uint money) public payable {
        address payable contractLender = payable(address(this));
        require(money <= msg.value, "Not enough money sent");
        contractLender.transfer(money);
        moneyPool[msg.sender] = moneyPool[msg.sender].add(money);
        emit NewContribution(msg.sender, money);
    }

    receive() external payable {}

    function withdraw(uint money) public {
        require(moneyPool[msg.sender] >= money, "Not enough money on account");
        address payable lender = payable(address(msg.sender));
        lender.transfer(money);
        moneyPool[msg.sender] = moneyPool[msg.sender].sub(money);
        emit NewExtraction(msg.sender, money);
    }

    function balance() public view returns (uint) {
        return moneyPool[msg.sender];
    }

}
