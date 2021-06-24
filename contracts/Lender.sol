//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hardhat/console.sol";

contract Lender is Ownable {

    using SafeMath for uint256;

    IERC20 public daiToken;

    event NewContribution(address indexed lender, uint amount);
    event NewExtraction(address indexed lender, uint amount);

    mapping (address => uint) loans;
    mapping (address => uint) moneyPool;

    constructor(address daiAddress) {
        daiToken = IERC20(daiAddress);
    }

    function pool(uint amount) public payable {
        daiToken.transfer(address(this), amount);
        moneyPool[msg.sender] = moneyPool[msg.sender].add(amount);
        emit NewContribution(msg.sender, amount);
    }

    function withdraw(uint money) public {
        require(moneyPool[msg.sender] >= money, "Not enough money on account");
        daiToken.transfer(address(msg.sender), money);
        moneyPool[msg.sender] = moneyPool[msg.sender].sub(money);
        emit NewExtraction(msg.sender, money);
    }

    function balance() public view returns (uint) {
        return moneyPool[msg.sender];
    }

}
