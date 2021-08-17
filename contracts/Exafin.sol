// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IExafin.sol";
import "./utils/TSUtils.sol";
import "hardhat/console.sol";

contract Exafin is Ownable, IExafin {

    using SafeCast for uint256;
    using TSUtils for uint256;
    using SafeERC20 for IERC20;

    struct Pool {
        uint256 totalLent;
        uint256 totalOwed;
    }

    mapping(uint256 => mapping(address => uint256)) borrowerAmounts;
    mapping(uint256 => mapping(address => uint256)) lenderAmounts; 
    mapping(uint256 => Pool) public pools;
    mapping(address => uint256[]) public addressPools;

    IERC20 private underlying;

    constructor (address stableAddress) onlyOwner {
        underlying = IERC20(stableAddress);
    }

    function rateLend(address from, uint256 amount, uint256 maturityDate) public view returns (uint256) {
        uint dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool for that date has reached maturity");

        uint256 daysDifference = (maturityDate - block.timestamp).trimmedDay() / 1 days;
        return daysDifference * 5e18 / 100; // 0.05 per day
    }

    function rateBorrow(address to, uint256 amount, uint256 maturityDate) public view returns (uint256) {
        uint dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool for that date has reached maturity");

        uint256 daysDifference = (maturityDate - block.timestamp).trimmedDay() / 1 days;

        Pool memory pool = pools[dateId];
        pool.totalLent += amount;

        uint256 utilizationRatio = pool.totalLent / pool.totalOwed;
        return utilizationRatio * 15/10 + daysDifference * 5/100; // 0.05 per day
    }

    /**
        @dev Borrows for a certain maturity date/pool
        @param to wallet to send the borrowed amount
        @param amount amount to send to the specified wallet
        @param maturityDate maturity date 
     */
    function borrow(address to, uint256 amount, uint256 maturityDate) public {
        uint dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool for that date has reached maturity");

        uint256 borrowedForDate = borrowerAmounts[dateId][to];
        require(borrowedForDate == 0, "Exafin: Wallet already has a loan for this maturity");

        underlying.safeTransferFrom(address(this), to, amount);

        uint256 commission = rateBorrow(to, amount, maturityDate);
    }

    /**
        @dev Lends for a certain maturity date/pool
        @param from wallet to receive amount from
        @param amount amount to receive from the specified wallet
        @param maturityDate maturity date 
     */
    function lend(address from, uint256 amount, uint256 maturityDate) public {

        uint dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool for that date has reached maturity");

        uint256 borrowedForDate = lenderAmounts[dateId][from];
        require(borrowedForDate == 0, "Exafin: Wallet already has a supply for this maturity");

        underlying.safeTransferFrom(from, address(this), amount);
    }

    /**
        @dev Converts any timestamp to one of the pool's indexes
        @param timestamp uint
        @return uint256 is the timestamp cropped to match a pool id
     */
    function nextPoolIndex(uint timestamp) private pure returns (uint256) {
        uint poolindex = timestamp.trimmedMonth().nextMonth();
        return poolindex;
    }

}
