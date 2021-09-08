// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IExafin.sol";
import "./interfaces/IExaFront.sol";
import "./utils/TSUtils.sol";
import {Error} from "./utils/Errors.sol";
import "hardhat/console.sol";

contract Exafin is Ownable, IExafin {
    using SafeCast for uint256;
    using TSUtils for uint256;
    using SafeERC20 for IERC20;

    event Borrowed(
        address indexed to,
        uint256 amount,
        uint256 commission,
        uint256 maturityDate
    );
    event Supplied(
        address indexed from,
        uint256 amount,
        uint256 commission,
        uint256 maturityDate
    );

    mapping(uint256 => mapping(address => uint256)) public suppliedAmmounts;
    mapping(uint256 => mapping(address => uint256)) public borrowedAmounts;
    mapping(uint256 => Pool) public pools;
    mapping(address => uint256[]) public addressPools;

    uint256 private baseRate;
    uint256 private marginRate;
    uint256 private slopeRate;
    uint256 private constant RATE_UNIT = 1e18;

    IERC20 private trustedUnderlying;
    string public override tokenName;

    IExaFront private exaFront;

    constructor(
        address _tokenAddress,
        string memory _tokenName,
        address _exaFrontAddress
    ) {
        trustedUnderlying = IERC20(_tokenAddress);
        trustedUnderlying.safeApprove(address(this), type(uint256).max);
        tokenName = _tokenName;

        exaFront = IExaFront(_exaFrontAddress);

        baseRate = 2e16; // 0.02
        marginRate = 1e16; // 0.01 => Difference between rate to borrow from and to lend to
        slopeRate = 7e16; // 0.07
    }

    /**
        @dev Rate that the protocol will pay when borrowing from an address a certain amount
             at the end of the maturity date
        @param amount amount to calculate how it would affect the pool 
        @param maturityDate maturity date to calculate the pool
     */
    function rateForSupply(uint256 amount, uint256 maturityDate)
        public
        view
        override
        returns (uint256, Pool memory)
    {
        uint256 dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool Matured");

        Pool memory pool = pools[dateId];
        pool.supplied += amount;

        uint256 daysDifference = (dateId - block.timestamp.trimmedDay()) /
            1 days;
        uint256 yearlyRate = baseRate +
            ((slopeRate * pool.lent) / pool.supplied);

        return ((yearlyRate * daysDifference) / 365, pool);
    }

    /**
        @dev Rate that the protocol will collect when lending to an address a certain amount
             at the end of the maturity date
        @param amount amount to calculate how it would affect the pool 
        @param maturityDate maturity date to calculate the pool
     */
    function rateToBorrow(uint256 amount, uint256 maturityDate)
        public
        view
        override
        returns (uint256, Pool memory)
    {
        uint256 dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool Matured");

        Pool memory pool = pools[dateId];
        pool.lent += amount;

        uint256 daysDifference = (dateId - block.timestamp.trimmedDay()) /
            1 days;
        uint256 yearlyRate = baseRate +
            marginRate +
            ((slopeRate * pool.lent) / pool.supplied);

        return ((yearlyRate * daysDifference) / 365, pool);
    }

    /**
        @dev Lends to a wallet for a certain maturity date/pool
        @param to wallet to send the amount
        @param amount amount to send to the specified wallet
        @param maturityDate maturity date for repayment
     */
    function borrow(
        address to,
        uint256 amount,
        uint256 maturityDate
    ) public override {
        uint256 dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool Matured");

        (uint256 commissionRate, Pool memory newPoolState) = rateToBorrow(
            amount,
            maturityDate
        );

        uint256 errorCode = exaFront.borrowAllowed(
            address(this),
            to,
            amount,
            maturityDate
        );
        if (errorCode != uint256(Error.NO_ERROR)) {
            revert("exaFront not allowing borrow");
        }

        uint256 commission = (amount * commissionRate) / RATE_UNIT;
        borrowedAmounts[dateId][to] += amount + commission;
        pools[dateId] = newPoolState;

        trustedUnderlying.safeTransferFrom(address(this), to, amount);

        emit Borrowed(to, amount, commission, dateId);
    }

    /**
        @dev Borrows from a wallet for a certain maturity date/pool
        @param from wallet to receive amount from
        @param amount amount to receive from the specified wallet
        @param maturityDate maturity date 
     */
    function supply(
        address from,
        uint256 amount,
        uint256 maturityDate
    ) public override {
        uint256 dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool Matured");

        (uint256 commissionRate, Pool memory newPoolState) = rateForSupply(
            amount,
            maturityDate
        );

        uint256 commission = ((amount * commissionRate) / RATE_UNIT);
        suppliedAmmounts[dateId][from] += amount + commission;
        pools[dateId] = newPoolState;

        trustedUnderlying.safeTransferFrom(from, address(this), amount);

        emit Supplied(from, amount, commission, dateId);
    }

    /**
        @dev Gets current snapshot for a wallet in a certain maturity
        @param who wallet to return status snapshot in the specified maturity date
        @param maturityDate maturity date
     */
    function getAccountSnapshot(address who, uint256 maturityDate)
        public
        view
        override
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 dateId = nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Exafin: Pool Matured");

        return (0, suppliedAmmounts[dateId][who], borrowedAmounts[dateId][who]);
    }

    /**
        @dev Gets the total amount of borrowed money for a maturityDate
        @param maturityDate maturity date
     */
    function getTotalBorrows(uint256 maturityDate)
        public
        view
        override
        returns (uint256)
    {
        uint256 dateId = nextPoolIndex(maturityDate);
        return pools[dateId].lent;
    }

    /**
        @dev Converts any timestamp to one of the pool's indexes
        @param timestamp uint
        @return uint256 is the timestamp cropped to match a pool id
     */
    function nextPoolIndex(uint256 timestamp) private pure returns (uint256) {
        uint256 poolindex = timestamp.trimmedMonth().nextMonth();
        return poolindex;
    }
}
