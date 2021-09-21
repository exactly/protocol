// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IExafin.sol";
import "./interfaces/IAuditor.sol";
import "./utils/TSUtils.sol";
import {Error} from "./utils/Errors.sol";
import "hardhat/console.sol";

contract Exafin is Ownable, IExafin {
    using SafeCast for uint256;
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

    event Redeemed(
        address indexed from,
        uint256 amount,
        uint256 maturityDate
    );

    event Repaid(
        address indexed payer,
        address indexed borrower,
        uint256 amount,
        uint256 maturityDate
    );

    mapping(uint256 => mapping(address => uint256)) public suppliedAmounts;
    mapping(uint256 => mapping(address => uint256)) public borrowedAmounts;
    mapping(uint256 => Pool) public pools;
    mapping(address => uint256[]) public addressPools;

    uint256 private baseRate;
    uint256 private marginRate;
    uint256 private slopeRate;
    uint256 private constant RATE_UNIT = 1e18;

    IERC20 private trustedUnderlying;
    string public override tokenName;

    IAuditor private auditor;

    constructor(
        address _tokenAddress,
        string memory _tokenName,
        address _auditorAddress
    ) {
        trustedUnderlying = IERC20(_tokenAddress);

        tokenName = _tokenName;

        auditor = IAuditor(_auditorAddress);

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
        uint256 dateId = TSUtils.nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Pool Matured");

        Pool memory pool = pools[dateId];
        pool.supplied += amount;

        uint256 daysDifference = (dateId - TSUtils.trimmedDay(block.timestamp)) /
            1 days;
        uint256 yearlyRate = baseRate +
            ((slopeRate * pool.borrowed) / pool.supplied);

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
        uint256 dateId = TSUtils.nextPoolIndex(maturityDate);
        require(block.timestamp < dateId, "Pool Matured");

        Pool memory pool = pools[dateId];
        pool.borrowed += amount;

        uint256 daysDifference = (dateId - TSUtils.trimmedDay(block.timestamp)) /
            1 days;
        uint256 yearlyRate = baseRate +
            marginRate +
            ((slopeRate * pool.borrowed) / pool.supplied);

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

        (uint256 commissionRate, Pool memory newPoolState) = rateToBorrow(
            amount,
            maturityDate
        );

        uint256 errorCode = auditor.borrowAllowed(
            address(this),
            to,
            amount,
            maturityDate
        );

        uint256 dateId = TSUtils.nextPoolIndex(maturityDate);

        require(
            errorCode == uint256(Error.NO_ERROR),
            "Auditor not allowing borrow"
        );

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

        (uint256 commissionRate, Pool memory newPoolState) = rateForSupply(
            amount,
            maturityDate
        );

        uint256 errorCode = auditor.supplyAllowed(
            address(this),
            from,
            amount,
            maturityDate
        );

        require(
            errorCode == uint256(Error.NO_ERROR),
            "Auditor not allowing borrow"
        );

        uint256 dateId = TSUtils.nextPoolIndex(maturityDate);
        uint256 commission = ((amount * commissionRate) / RATE_UNIT);
        suppliedAmounts[dateId][from] += amount + commission;
        pools[dateId] = newPoolState;

        trustedUnderlying.safeTransferFrom(from, address(this), amount);

        emit Supplied(from, amount, commission, dateId);
    }

    /**
        @notice User redeems (TODO: voucher NFT) in exchange for the underlying asset
        @dev The pool that the user is trying to retrieve the money should be matured
        @param redeemer The address of the account which is redeeming the tokens
        @param redeemAmount The number of underlying tokens to receive from redeeming this Exafin (only one of redeemTokensIn or redeemAmountIn may be non-zero)
        @param maturityDate the date to calculate the pool id
     */
    function redeem(
        address payable redeemer,
        uint256 redeemAmount,
        uint256 maturityDate
    ) external override {
        require(redeemAmount != 0, "Redeem can't be zero");

        uint256 allowedError = auditor.redeemAllowed(
            address(this),
            redeemer,
            redeemAmount,
            maturityDate
        );
        require(allowedError == uint(Error.NO_ERROR), "cant redeem");

        uint dateId = TSUtils.nextPoolIndex(maturityDate);
        suppliedAmounts[dateId][redeemer] -= redeemAmount;

        require(
            trustedUnderlying.balanceOf(address(this)) >
                redeemAmount,
            "Not enough liquidity"
        );

        trustedUnderlying.safeTransferFrom(
            address(this),
            redeemer,
            redeemAmount 
        );

        emit Redeemed(redeemer, redeemAmount, maturityDate);
    }

    /**
        @notice User repays its debt
        @dev The pool that the user is trying to retrieve the money should be matured
        @param borrower The address of the account that has the debt
        @param repayAmount the amount of debt of the underlying token to be paid
        @param maturityDate the maturityDate to access the pool
     */
    function _repay(
        address payable payer,
        address borrower,
        uint256 repayAmount, 
        uint256 maturityDate
    ) internal {

        require(repayAmount != 0, "You can't repay zero");

        uint256 allowed = auditor.repayAllowed(
            address(this),
            borrower,
            repayAmount,
            maturityDate
        );
        require(allowed == uint(Error.NO_ERROR), "Not allowed");

        uint256 dateId = TSUtils.nextPoolIndex(maturityDate);

        // the commission is included
        uint256 amountBorrowed = borrowedAmounts[dateId][borrower];

        require(amountBorrowed == repayAmount, "debt must be paid in full");

        trustedUnderlying.safeTransferFrom(
            payer,
            address(this),
            repayAmount
        );

        delete borrowedAmounts[dateId][borrower];

        emit Repaid(payer, borrower, repayAmount, maturityDate);
    }

    /**
        @notice User repays its debt
        @dev The pool that the user is trying to retrieve the money should be matured
        @param borrower The address of the account that has the debt
        @param repayAmount the amount of debt of the underlying token to be paid
     */
    function repay(
        address payable payer,
        address borrower,
        uint256 repayAmount, 
        uint256 maturityDate
    ) override external {
        _repay(payer, borrower, repayAmount, maturityDate);
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
            uint256
        )
    {
        uint256 dateId = TSUtils.nextPoolIndex(maturityDate);
        return (suppliedAmounts[dateId][who], borrowedAmounts[dateId][who]);
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
        uint256 dateId = TSUtils.nextPoolIndex(maturityDate);
        return pools[dateId].borrowed;
    }


    function getAuditor() override public view returns (IAuditor) {
        return IAuditor(auditor);
    }
}
