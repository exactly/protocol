//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract Lender is Ownable {

    using SafeMath for uint256;

    event NewContribution(address indexable lender, uint amount);
    event NewExtraction(address indexable lender, uint amount);

    mapping (address => uint) loans;
    mapping (address => uint) moneyPool;

    function pool(uint money) public payable {
        address payable contractLender = payable(address(this));
        moneyPool[msg.sender] = moneyPool[msg.sender].add(money);
        contractLender.transfer(money);
        emit NewContribution(msg.sender, money);
    }

    function withdraw(uint money) public payable {
        require(moneyPool[msg.sender] >= money);
        address payable lender = payable(address(msg.sender));
        moneyPool[msg.sender] = moneyPool[msg.sender].sub(money);
        lender.transfer(money);
        emit NewExtraction(msg.sender, money);
    }

}
