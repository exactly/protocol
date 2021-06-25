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

    function pool() public payable {
        uint amount = msg.value;
        require(amount > 0, "You need to send some money");

        uint256 allowance = daiToken.allowance(msg.sender, address(this));
        require(allowance >= amount, "Check the token allowance");

        daiToken.transferFrom(msg.sender, address(this), amount);

        uint moneyInPool = moneyPool[msg.sender];
        moneyPool[msg.sender] = moneyInPool.add(amount);

        emit NewContribution(msg.sender, amount);
    }

    function withdraw(uint money) public {
        uint moneyInPool = moneyPool[msg.sender];
        require(moneyInPool >= money, "Not enough money on account");

        daiToken.transfer(address(msg.sender), money);

        moneyPool[msg.sender] = moneyInPool.sub(money);
        emit NewExtraction(msg.sender, money);
    }

    function balance() public view returns (uint) {
        return moneyPool[msg.sender];
    }

}
