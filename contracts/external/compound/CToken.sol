// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../../interfaces/ICToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 @dev this class is only for mocking Compound's cToken contract
 */
contract CToken is ICToken, ERC20 {

    constructor (string memory name_, string memory symbol_, address daiAddress) ERC20 (name_, symbol_) {
        dai = IERC20(daiAddress);
    }

    mapping(address => uint256) public balance;

    uint256 constant public UNIT = 1e18;

    IERC20 dai;

    function exchangeRateCurrent() external override returns (uint256) {
        // silence warning "convert to pure" and simulate cToken's gas consumption
        balance[msg.sender] = balance[msg.sender];
        return 12 * UNIT / 10;
    }
    
    /**
     @dev Redeem the amount of cTokens to the underlaying ERC20
     */
    function redeem(uint amount) external override returns (uint) {
        uint balanceAmount = balance[msg.sender];
        require(balanceAmount - amount > 0, "Not enough balance");
        balance[msg.sender] = balanceAmount - amount;
        dai.transfer(msg.sender, balanceAmount * this.exchangeRateCurrent());
        return 0;
    }

    /**
     @dev Redeem the amount of cTokens(in DAI) to the underlaying ERC20
     */
    function redeemUnderlying(uint amount) external override returns (uint) {
        uint balanceAmount = balance[msg.sender];
        require(balanceAmount * this.exchangeRateCurrent() - amount > 0, "Not enough balance");
        uint amountDai = amount / this.exchangeRateCurrent();
        balance[msg.sender] = balanceAmount - amount;
        dai.transfer(msg.sender, amountDai);
        return 0;
    }

    function mint(uint256 amount) external override returns (uint256) {
        dai.transferFrom(msg.sender, address(this), amount);
        uint oldBalance = balance[msg.sender];
        balance[msg.sender] = oldBalance + amount;
        return amount;
    }
}