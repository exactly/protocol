// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IExafin.sol";
import "./interfaces/IAuditor.sol";
import "./utils/TSUtils.sol";
import "./utils/DecimalMath.sol";
import {Error} from "./utils/Errors.sol";
import "hardhat/console.sol";

contract Exafin is Ownable, IExafin, ReentrancyGuard {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using DecimalMath for uint256;

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

    event LiquidateBorrow(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        address exafinCollateral,
        uint256 seizeAmount,
        uint256 maturityDate
    );

    event Seized(
        address liquidator,
        address borrower,
        uint256 seizedAmount,
        uint256 maturityDate
    );

    event ReservesAdded(
        address benefactor,
        uint256 addAmount
    );


    mapping(uint256 => mapping(address => uint256)) public suppliedAmounts;
    mapping(uint256 => mapping(address => uint256)) public borrowedAmounts;
    mapping(uint256 => Pool) public pools;
    mapping(address => uint256[]) public addressPools;

    uint256 private baseRate;
    uint256 private marginRate;
    uint256 private slopeRate;
    uint256 private constant RATE_UNIT = 1e18;
    uint256 private constant PROTOCOL_SEIZE_SHARE = 2.8e16; //2.8%

    IERC20 private trustedUnderlying;
    string public override tokenName;

    IAuditor private auditor;

    constructor(
        address _tokenAddress,
        string memory _tokenName,
        address _auditorAddress
    ) {
        trustedUnderlying = IERC20(_tokenAddress);
        trustedUnderlying.safeApprove(address(this), type(uint256).max);
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
        require(TSUtils.isPoolID(maturityDate) == true, "Not a pool ID");
        require(block.timestamp < maturityDate, "Pool Matured");

        Pool memory pool = pools[maturityDate];
        pool.supplied += amount;

        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;
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
        require(TSUtils.isPoolID(maturityDate) == true, "Not a pool ID");
        require(block.timestamp < maturityDate, "Pool Matured");

        Pool memory pool = pools[maturityDate];
        pool.borrowed += amount;

        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;
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
    ) override public nonReentrant {
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

        require(
            errorCode == uint256(Error.NO_ERROR),
            "Auditor not allowing borrow"
        );

        uint256 commission = (amount * commissionRate) / RATE_UNIT;
        borrowedAmounts[maturityDate][to] += amount + commission;
        pools[maturityDate] = newPoolState;

        trustedUnderlying.safeTransferFrom(address(this), to, amount);

        emit Borrowed(to, amount, commission, maturityDate);
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
    ) override public nonReentrant {
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

        uint256 commission = ((amount * commissionRate) / RATE_UNIT);
        suppliedAmounts[maturityDate][from] += amount + commission;
        pools[maturityDate] = newPoolState;

        trustedUnderlying.safeTransferFrom(from, address(this), amount);

        emit Supplied(from, amount, commission, maturityDate);
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
    ) external override nonReentrant {
        require(redeemAmount != 0, "Redeem can't be zero");

        uint256 allowedError = auditor.redeemAllowed(
            address(this),
            redeemer,
            redeemAmount,
            maturityDate
        );
        require(allowedError == uint256(Error.NO_ERROR), "cant redeem");

        suppliedAmounts[maturityDate][redeemer] -= redeemAmount;

        require(
            trustedUnderlying.balanceOf(address(this)) > redeemAmount,
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
        address payer,
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
        require(allowed == uint256(Error.NO_ERROR), "Not allowed");

        // the commission is included
        uint256 amountBorrowed = borrowedAmounts[maturityDate][borrower];
        require(amountBorrowed == repayAmount, "debt must be paid in full");

        trustedUnderlying.safeTransferFrom(payer, address(this), repayAmount);

        delete borrowedAmounts[maturityDate][borrower];

        emit Repaid(payer, borrower, repayAmount, maturityDate);
    }

    /**
        @notice This function allows to partially repay a position on liquidation
        @dev repay function on liquidation, it allows to partially pay debt, and it
             doesn't check `repayAllowed` on the auditor. It should be called after 
             liquidateAllowed
        @param payer The address of the account that will pay the debt
        @param borrower The address of the account that has the debt
        @param repayAmount the amount of debt of the pool that should be paid
        @param maturityDate the maturityDate to access the pool
     */
    function _repayLiquidate(
        address payer,
        address borrower,
        uint256 repayAmount,
        uint256 maturityDate
    ) internal {
        require(repayAmount != 0, "You can't repay zero");

        uint256 amountBorrowed = borrowedAmounts[maturityDate][borrower];

        trustedUnderlying.safeTransferFrom(payer, address(this), repayAmount);

        borrowedAmounts[maturityDate][borrower] = amountBorrowed - repayAmount;

        // That repayment diminishes debt in the pool
        Pool memory pool = pools[maturityDate];
        pool.borrowed -= repayAmount;
        pools[maturityDate] = pool;

        emit Repaid(payer, borrower, repayAmount, maturityDate);
    }

    function liquidate(
        address borrower,
        uint256 repayAmount,
        IExafin exafinCollateral,
        uint256 maturityDate
    ) override external nonReentrant returns (uint, uint) {
        return _liquidate(msg.sender, borrower, repayAmount, exafinCollateral, maturityDate);
    }

    function _liquidate(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        IExafin exafinCollateral,
        uint256 maturityDate
    ) internal returns (uint, uint) {

        uint allowed = auditor.liquidateAllowed(
            address(this),
            address(exafinCollateral),
            liquidator,
            borrower,
            repayAmount, 
            maturityDate
        );
        require(allowed == 0, "Auditor Rejected");

        _repayLiquidate(liquidator, borrower, repayAmount, maturityDate);

        (uint amountSeizeError, uint seizeTokens) = auditor.liquidateCalculateSeizeAmount(address(this), address(exafinCollateral), repayAmount);
        require(amountSeizeError == uint(Error.NO_ERROR), "Error calculating Seize");

        /* Revert if borrower collateral token balance < seizeTokens */
        (uint256 balance,) = exafinCollateral.getAccountSnapshot(borrower, maturityDate);
        require(balance >= seizeTokens, "LIQUIDATE_SEIZE_TOO_MUCH");

        // If this is also the collateral
        // run seizeInternal to avoid re-entrancy, otherwise make an external call
        uint seizeError;
        if (address(exafinCollateral) == address(this)) {
            seizeError = _seize(address(this), liquidator, borrower, seizeTokens, maturityDate);
        } else {
            seizeError = exafinCollateral.seize(liquidator, borrower, seizeTokens, maturityDate);
        }

        /* Revert if seize tokens fails (since we cannot be sure of side effects) */
        require(seizeError == uint(Error.NO_ERROR), "token seizure failed");

        /* We emit a LiquidateBorrow event */
        emit LiquidateBorrow(liquidator, borrower, repayAmount, address(exafinCollateral), seizeTokens, maturityDate);

        return (uint(Error.NO_ERROR), repayAmount);
    }

    function seize(
        address liquidator,
        address borrower,
        uint256 seizeTokens,
        uint256 maturityDate
    ) override external nonReentrant returns (uint) {
        // removing msg.sender from here means DEATH
        return _seize(msg.sender, liquidator, borrower, seizeTokens, maturityDate);
    }

    function _seize(
        address seizerToken,
        address liquidator,
        address borrower,
        uint256 seizeAmount,
        uint256 maturityDate
    ) internal returns (uint) {

        uint allowed = auditor.seizeAllowed(
            address(this),
            seizerToken,
            liquidator,
            borrower,
            seizeAmount
        );
        require(allowed == 0, "Seize Allowed Failed");

        uint256 protocolAmount = seizeAmount.mul_(PROTOCOL_SEIZE_SHARE);
        uint256 amountToTransfer = seizeAmount - protocolAmount;

        suppliedAmounts[maturityDate][borrower] -= seizeAmount;

        // That seize amount diminishes liquidity in the pool
        Pool memory pool = pools[maturityDate];
        pool.supplied -= seizeAmount;
        pools[maturityDate] = pool;

        trustedUnderlying.transfer(liquidator, amountToTransfer);

        emit Seized(liquidator, borrower, seizeAmount, maturityDate);
        emit ReservesAdded(address(this), protocolAmount);

        return uint(Error.NO_ERROR);
    }

    /**
        @notice Someone pays borrower's debt (can be borrower)
        @dev The pool that the user is trying to repay to should be matured
        @param borrower The address of the account that has the debt
        @param repayAmount the amount of debt of the underlying token to be paid
     */
    function repay(
        address borrower,
        uint256 repayAmount,
        uint256 maturityDate
    ) external override {
        _repay(msg.sender, borrower, repayAmount, maturityDate);
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
        returns (uint256, uint256)
    {
        require(TSUtils.isPoolID(maturityDate) == true, "Not a pool ID");
        return (suppliedAmounts[maturityDate][who], borrowedAmounts[maturityDate][who]);
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
        require(TSUtils.isPoolID(maturityDate) == true, "Not a pool ID");
        return pools[maturityDate].borrowed;
    }

    function getAuditor() public view override returns (IAuditor) {
        return IAuditor(auditor);
    }
}
