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

    event Borrowed(address indexed to, uint amount, uint maturityDate);
    event Lent(address indexed from, uint amount, uint maturityDate);
    
    mapping(uint256 => mapping(address => uint256)) public borrowedAmounts;
    mapping(uint256 => mapping(address => uint256)) public lentAmounts;
    mapping(uint256 => Pool) public pools;
    mapping(address => uint256[]) public addressPools;

    uint private baseRate;
    uint private marginRateLoco;
    uint private slopeRate;
    uint private constant RATE_UNIT = 1e18;

    IERC20 private trustedUnderlying;

    constructor (address stableAddress) {
        trustedUnderlying = IERC20(stableAddress);
        trustedUnderlying.safeApprove(address(this), type(uint256).max);
        baseRate = 2e16;   // 0.02
        marginRateLoco = 1e16; // 0.01 => Difference between rate to borrow from and to lend to
        slopeRate = 7e16;  // 0.07
    }

    /**
        @dev Rate that the protocol will pay when borrowing from an address a certain amount
             at the end of the maturity date
        @param amount amount to calculate how it would affect the pool 
        @param maturityDate maturity date to calculate the pool
     */
    function rateBorrow(uint256 amount, uint256 maturityDate) override public view returns (uint256, Pool memory) {
        uint dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool Matured");

        Pool memory pool = pools[dateId];
        pool.borrowed += amount;

        uint256 daysDifference = (dateId - block.timestamp).trimmedDay() / 1 days;
        uint256 utilizationRatio = (pool.lent * RATE_UNIT / pool.borrowed);
        uint256 yearlyRate = baseRate + (slopeRate * utilizationRatio) / RATE_UNIT;

        return ((yearlyRate * daysDifference) / 365, pool);
    }

    /**
        @dev Rate that the protocol will collect when lending to an address a certain amount
             at the end of the maturity date
        @param amount amount to calculate how it would affect the pool 
        @param maturityDate maturity date to calculate the pool
     */
    function rateLend(uint256 amount, uint256 maturityDate) override public view returns (uint256, Pool memory) {
        uint dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool Matured");

        Pool memory pool = pools[dateId];
        pool.lent += amount;

        uint256 daysDifference = (dateId - block.timestamp).trimmedDay() / 1 days;
        uint256 utilizationRatio = (pool.lent * RATE_UNIT / pool.borrowed);
        uint256 yearlyRate = baseRate + marginRate + (slopeRate * utilizationRatio) / RATE_UNIT;

        return ((yearlyRate * daysDifference) / 365, pool);
    }

    /**
        @dev Lends to a wallet for a certain maturity date/pool
        @param to wallet to send the amount
        @param amount amount to send to the specified wallet
        @param maturityDate maturity date for repayment
     */
    function lend(address to, uint256 amount, uint256 maturityDate) override public {
       
        uint dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool Matured");

        uint256 lentForDate = lentAmounts[dateId][to];
        require(lentForDate == 0, "Exafin: Wallet Already Used");

        trustedUnderlying.safeTransferFrom(address(this), to, amount);

        (uint256 commission, Pool memory newPoolState) = rateLend(amount, maturityDate);

        lentAmounts[dateId][to] = amount + commission;
        pools[dateId] = newPoolState;

        emit Lent(to, amount, dateId);
    }

    /**
        @dev Borrows from a wallet for a certain maturity date/pool
        @param from wallet to receive amount from
        @param amount amount to receive from the specified wallet
        @param maturityDate maturity date 
     */
    function borrow(address from, uint256 amount, uint256 maturityDate) override public {
        
        uint dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool Matured");

        uint256 borrowedForDate = borrowedAmounts[dateId][from];
        require(borrowedForDate == 0, "Exafin: Wallet Already Used");

        trustedUnderlying.safeTransferFrom(from, address(this), amount);

        (uint256 commission, Pool memory newPoolState) = rateBorrow(amount, maturityDate);

        // Commission for now it's 18 decimals. TODO: make it dependent on underlying's decimals
        lentAmounts[dateId][from] = amount + commission;
        pools[dateId] = newPoolState;

        emit Borrowed(from, amount, dateId);
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
