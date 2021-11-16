// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./EToken.sol";
import "./interfaces/IExafin.sol";
import "./interfaces/IAuditor.sol";
import "./interfaces/IEToken.sol";
import "./interfaces/IInterestRateModel.sol";
import "./utils/TSUtils.sol";
import "./utils/DecimalMath.sol";
import "./utils/Errors.sol";
import "hardhat/console.sol";

contract Exafin is IExafin, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using DecimalMath for uint256;
    using PoolLib for PoolLib.Pool;

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

    event Redeemed(address indexed from, uint256 amount, uint256 maturityDate);

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
    event ReservesAdded(address benefactor, uint256 addAmount);

    event DepositToSmartPool(address indexed user, uint256 amount);
    event WithdrawFromSmartPool(address indexed user, uint256 amount);

    mapping(uint256 => mapping(address => uint256)) public suppliedAmounts;
    mapping(uint256 => mapping(address => uint256)) public borrowedAmounts;
    mapping(uint256 => PoolLib.Pool) public pools;
    mapping(address => uint256[]) public addressPools;

    uint256 private constant PROTOCOL_SEIZE_SHARE = 2.8e16; //2.8%

    PoolLib.SmartPool public smartPool;

    IERC20 private trustedUnderlying;
    IEToken public override eToken;
    string public override underlyingTokenName;

    IAuditor public auditor;
    IInterestRateModel public interestRateModel;

    // Total deposits in all maturities
    uint256 public override totalDeposits;
    mapping(address => uint256) public override totalDepositsUser;

    // Total borrows in all maturities
    uint256 public override totalBorrows;
    mapping(address => uint256) public override totalBorrowsUser;

    constructor(
        address _tokenAddress,
        string memory _underlyingTokenName,
        address _eTokenAddress,
        address _auditorAddress,
        address _interestRateModelAddress
    ) {
        trustedUnderlying = IERC20(_tokenAddress);
        trustedUnderlying.safeApprove(address(this), type(uint256).max);
        underlyingTokenName = _underlyingTokenName;

        auditor = IAuditor(_auditorAddress);
        eToken = IEToken(_eTokenAddress);
        interestRateModel = IInterestRateModel(_interestRateModelAddress);

        smartPool.borrowed = 0;
        smartPool.supplied = 0;
    }

    /**
     * @dev Lends to a wallet for a certain maturity date/pool
     * @param amount amount to send to the specified wallet
     * @param maturityDate maturity date for repayment
     */
    function borrow(uint256 amount, uint256 maturityDate)
        public
        override
        nonReentrant
    {
        bool newDebt = false;

        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        auditor.requirePoolState(maturityDate, TSUtils.State.VALID);
        PoolLib.Pool memory pool = pools[maturityDate];

        pool.borrowed = pool.borrowed + amount;
        if (amount > pool.available) {
            smartPool.borrowed = smartPool.borrowed + amount - pool.available;
            pool.debt = pool.debt + amount - pool.available;
            pool.supplied = pool.supplied + amount - pool.available;
            pool.available = 0;
            newDebt = true;
        } else {
            pool.available = pool.available - amount;
        }

        uint256 commissionRate = interestRateModel.getRateToBorrow(
            maturityDate,
            pool,
            smartPool,
            newDebt
        );
        uint256 commission = amount.mul_(commissionRate);
        uint256 totalBorrow = amount + commission;
        // reverts on failure
        auditor.borrowAllowed(
            address(this),
            msg.sender,
            totalBorrow,
            maturityDate
        );

        pool.borrowed = pool.borrowed + commission;
        pools[maturityDate] = pool;

        uint256 currentTotalBorrow = amount + commission;
        borrowedAmounts[maturityDate][msg.sender] += currentTotalBorrow;

        totalBorrows += currentTotalBorrow;
        totalBorrowsUser[msg.sender] += currentTotalBorrow;

        trustedUnderlying.safeTransferFrom(address(this), msg.sender, amount);

        emit Borrowed(msg.sender, amount, commission, maturityDate);
    }

    /**
     * @dev Supplies a certain amount to the protocol for
     *      a certain maturity date/pool
     * @param from wallet to receive amount from
     * @param amount amount to receive from the specified wallet
     * @param maturityDate maturity date / pool ID
     */
    function supply(
        address from,
        uint256 amount,
        uint256 maturityDate
    ) public override nonReentrant {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        PoolLib.Pool memory pool = pools[maturityDate];

        // reverts on failure
        auditor.supplyAllowed(address(this), from, amount, maturityDate);

        if (pool.debt > 0) {
            if (amount >= pool.debt) {
                pool.debt = 0;
                pool.supplied = pool.supplied + amount;
                pool.available = amount;
            } else {
                pool.debt = pool.debt - amount;
                smartPool.supplied = smartPool.supplied + amount;
            }
        } else {
            pool.supplied = pool.supplied + amount;
            pool.available = pool.available + amount;
        }

        pools[maturityDate] = pool;

        uint256 commissionRate = interestRateModel.getRateToSupply(
            maturityDate,
            pool
        );

        uint256 commission = amount.mul_(commissionRate);
        uint256 currentTotalDeposit = amount + commission;
        suppliedAmounts[maturityDate][from] += currentTotalDeposit;

        totalDeposits += currentTotalDeposit;
        totalDepositsUser[from] += currentTotalDeposit;

        trustedUnderlying.safeTransferFrom(from, address(this), amount);

        emit Supplied(from, amount, commission, maturityDate);
    }

    /**
     * @notice User collects a certain amount of underlying asset after having
     *         supplied tokens until a certain maturity date
     * @dev The pool that the user is trying to retrieve the money should be matured
     * @param redeemer The address of the account which is redeeming the tokens
     * @param redeemAmount The number of underlying tokens to receive from redeeming this Exafin
     * @param maturityDate the matured date for which we're trying to retrieve the funds
     */
    function redeem(
        address payable redeemer,
        uint256 redeemAmount,
        uint256 maturityDate
    ) external override nonReentrant {
        if (redeemAmount == 0) {
            revert GenericError(ErrorCode.REDEEM_CANT_BE_ZERO);
        }

        // reverts on failure
        auditor.redeemAllowed(
            address(this),
            redeemer,
            redeemAmount,
            maturityDate
        );

        suppliedAmounts[maturityDate][redeemer] -= redeemAmount;
        totalDeposits -= redeemAmount;
        totalDepositsUser[redeemer] -= redeemAmount;

        require(
            trustedUnderlying.balanceOf(address(this)) >= redeemAmount,
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
     * @notice Sender repays borrower's debt for a maturity date
     * @dev The pool that the user is trying to repay to should be matured
     * @param borrower The address of the account that has the debt
     * @param maturityDate The matured date where the debt is located
     */
    function repay(address borrower, uint256 maturityDate)
        external
        override
        nonReentrant
    {
        // reverts on failure
        auditor.repayAllowed(address(this), borrower, maturityDate);

        // the commission is included
        uint256 amountBorrowed = borrowedAmounts[maturityDate][borrower];

        trustedUnderlying.safeTransferFrom(
            msg.sender,
            address(this),
            amountBorrowed
        );
        totalBorrows -= amountBorrowed;
        totalBorrowsUser[borrower] -= amountBorrowed;

        delete borrowedAmounts[maturityDate][borrower];

        emit Repaid(msg.sender, borrower, amountBorrowed, maturityDate);
    }

    /**
     * @notice This function allows to partially repay a position on liquidation
     * @dev repay function on liquidation, it allows to partially pay debt, and it
     *      doesn't check `repayAllowed` on the auditor. It should be called after
     *      liquidateAllowed
     * @param payer The address of the account that will pay the debt
     * @param borrower The address of the account that has the debt
     * @param repayAmount the amount of debt of the pool that should be paid
     * @param maturityDate the maturityDate to access the pool
     */
    function _repayLiquidate(
        address payer,
        address borrower,
        uint256 repayAmount,
        uint256 maturityDate
    ) internal {
        require(repayAmount != 0, "You can't repay zero");

        trustedUnderlying.safeTransferFrom(payer, address(this), repayAmount);

        uint256 amountBorrowed = borrowedAmounts[maturityDate][borrower];
        borrowedAmounts[maturityDate][borrower] = amountBorrowed - repayAmount;

        // That repayment diminishes debt in the pool
        PoolLib.Pool memory pool = pools[maturityDate];
        pool.borrowed -= repayAmount;
        pools[maturityDate] = pool;

        totalBorrows -= repayAmount;
        totalBorrowsUser[borrower] -= repayAmount;

        emit Repaid(payer, borrower, repayAmount, maturityDate);
    }

    /**
     * @notice Function to liquidate an uncollaterized position
     * @dev Msg.sender liquidates a borrower's position and repays a certain amount of collateral
     *      for a maturity date, seizing a part of borrower's collateral
     * @param borrower wallet that has an outstanding debt for a certain maturity date
     * @param repayAmount amount to be repaid by liquidator(msg.sender)
     * @param exafinCollateral address of exafin from which the collateral will be seized to give the liquidator
     * @param maturityDate maturity date for which the position will be liquidated
     */
    function liquidate(
        address borrower,
        uint256 repayAmount,
        IExafin exafinCollateral,
        uint256 maturityDate
    ) external override nonReentrant returns (uint256) {
        return
            _liquidate(
                msg.sender,
                borrower,
                repayAmount,
                exafinCollateral,
                maturityDate
            );
    }

    /**
     * @notice Internal Function to liquidate an uncollaterized position
     * @dev Liquidator liquidates a borrower's position and repays a certain amount of collateral
     *      for a maturity date, seizing a part of borrower's collateral
     * @param borrower wallet that has an outstanding debt for a certain maturity date
     * @param repayAmount amount to be repaid by liquidator(msg.sender)
     * @param exafinCollateral address of exafin from which the collateral will be seized to give the liquidator
     * @param maturityDate maturity date for which the position will be liquidated
     */
    function _liquidate(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        IExafin exafinCollateral,
        uint256 maturityDate
    ) internal returns (uint256) {
        // reverts on failure
        auditor.liquidateAllowed(
            address(this),
            address(exafinCollateral),
            liquidator,
            borrower,
            repayAmount,
            maturityDate
        );

        _repayLiquidate(liquidator, borrower, repayAmount, maturityDate);

        // reverts on failure
        uint256 seizeTokens = auditor.liquidateCalculateSeizeAmount(
            address(this),
            address(exafinCollateral),
            repayAmount
        );

        /* Revert if borrower collateral token balance < seizeTokens */
        (uint256 balance, ) = exafinCollateral.getAccountSnapshot(
            borrower,
            maturityDate
        );
        if (balance < seizeTokens) {
            revert GenericError(ErrorCode.TOKENS_MORE_THAN_BALANCE);
        }

        // If this is also the collateral
        // run seizeInternal to avoid re-entrancy, otherwise make an external call
        // both revert on failure
        if (address(exafinCollateral) == address(this)) {
            _seize(
                address(this),
                liquidator,
                borrower,
                seizeTokens,
                maturityDate
            );
        } else {
            exafinCollateral.seize(
                liquidator,
                borrower,
                seizeTokens,
                maturityDate
            );
        }

        /* We emit a LiquidateBorrow event */
        emit LiquidateBorrow(
            liquidator,
            borrower,
            repayAmount,
            address(exafinCollateral),
            seizeTokens,
            maturityDate
        );

        return repayAmount;
    }

    /**
     * @notice Public function to seize a certain amount of tokens
     * @dev Public function for liquidator to seize borrowers tokens in a certain maturity date.
     *      This function will only be called from another Exafins, on `liquidation` calls.
     *      That's why msg.sender needs to be passed to the private function (to be validated as a market)
     * @param liquidator address which will receive the seized tokens
     * @param borrower address from which the tokens will be seized
     * @param seizeAmount amount to be removed from borrower's posession
     * @param maturityDate maturity date from where the tokens will be removed. Used to remove liquidity.
     */
    function seize(
        address liquidator,
        address borrower,
        uint256 seizeAmount,
        uint256 maturityDate
    ) external override nonReentrant {
        _seize(msg.sender, liquidator, borrower, seizeAmount, maturityDate);
    }

    /**
     * @notice Private function to seize a certain amount of tokens
     * @dev Private function for liquidator to seize borrowers tokens in a certain maturity date.
     *      This function will only be called from this Exafin, on `liquidation` or through `seize` calls from another Exafins.
     *      That's why msg.sender needs to be passed to the private function (to be validated as a market)
     * @param seizerExafin address which is calling the seize function (see `seize` public function)
     * @param liquidator address which will receive the seized tokens
     * @param borrower address from which the tokens will be seized
     * @param seizeAmount amount to be removed from borrower's posession
     * @param maturityDate maturity date from where the tokens will be removed. Used to remove liquidity.
     */
    function _seize(
        address seizerExafin,
        address liquidator,
        address borrower,
        uint256 seizeAmount,
        uint256 maturityDate
    ) internal {
        // reverts on failure
        auditor.seizeAllowed(address(this), seizerExafin, liquidator, borrower);

        uint256 protocolAmount = seizeAmount.mul_(PROTOCOL_SEIZE_SHARE);
        uint256 amountToTransfer = seizeAmount - protocolAmount;

        suppliedAmounts[maturityDate][borrower] -= seizeAmount;

        // That seize amount diminishes liquidity in the pool
        PoolLib.Pool memory pool = pools[maturityDate];
        pool.supplied -= seizeAmount;
        pools[maturityDate] = pool;

        totalDeposits -= seizeAmount;
        totalDepositsUser[borrower] -= seizeAmount;

        trustedUnderlying.safeTransfer(liquidator, amountToTransfer);

        emit Seized(liquidator, borrower, seizeAmount, maturityDate);
        emit ReservesAdded(address(this), protocolAmount);
    }

    /**
     * @dev Deposits an `amount` of underlying asset into the smart pool, receiving in return overlying eTokens.
     * - E.g. User deposits 100 USDC and gets in return 100 eUSDC
     * @param amount The amount to be deposited
     **/
    function depositToSmartPool(uint256 amount) external override {
        auditor.beforeSupplySmartPool(address(this), msg.sender);

        trustedUnderlying.safeTransferFrom(msg.sender, address(this), amount);

        eToken.mint(msg.sender, amount);

        emit DepositToSmartPool(msg.sender, amount);
    }

    /**
     * @dev Withdraws an `amount` of underlying asset from the smart pool, burning the equivalent eTokens owned
     * - E.g. User has 100 eUSDC, calls withdraw() and receives 100 USDC, burning the 100 eUSDC
     * @param amount The underlying amount to be withdrawn
     * - Send the value type(uint256).max in order to withdraw the whole eToken balance
     **/
    function withdrawFromSmartPool(uint256 amount) external override {
        auditor.beforeWithdrawSmartPool(address(this), msg.sender);
        
        uint256 userBalance = eToken.balanceOf(msg.sender);
        uint256 amountToWithdraw = amount;
        if (amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }

        eToken.burn(msg.sender, amountToWithdraw);
        trustedUnderlying.safeTransferFrom(address(this), msg.sender, amount);

        emit WithdrawFromSmartPool(msg.sender, amount);
    }

    /**
     * @dev Gets current snapshot for a wallet in a certain maturity
     * @param who wallet to return status snapshot in the specified maturity date
     * @param maturityDate maturity date
     */
    function getAccountSnapshot(address who, uint256 maturityDate)
        public
        view
        override
        returns (uint256, uint256)
    {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }
        return (
            suppliedAmounts[maturityDate][who],
            borrowedAmounts[maturityDate][who]
        );
    }

    /**
     * @dev Gets the total amount of borrowed money for a maturityDate
     * @param maturityDate maturity date
     */
    function getTotalBorrows(uint256 maturityDate)
        public
        view
        override
        returns (uint256)
    {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }
        return pools[maturityDate].borrowed;
    }

    /**
     * @dev Gets the auditor contract interface being used to validate positions
     */
    function getAuditor() public view override returns (IAuditor) {
        return IAuditor(auditor);
    }

}
