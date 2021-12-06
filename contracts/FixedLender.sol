// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./EToken.sol";
import "./interfaces/IFixedLender.sol";
import "./interfaces/IAuditor.sol";
import "./interfaces/IEToken.sol";
import "./interfaces/IInterestRateModel.sol";
import "./utils/TSUtils.sol";
import "./utils/DecimalMath.sol";
import "./utils/Errors.sol";

contract FixedLender is IFixedLender, ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;
    using DecimalMath for uint256;

    mapping(uint256 => mapping(address => uint256)) public mpUserSuppliedAmount;
    mapping(uint256 => mapping(address => uint256)) public mpUserBorrowedAmount;
    mapping(uint256 => PoolLib.MaturityPool) public maturityPools;
    PoolLib.SmartPool public smartPool;

    uint256 private liquidationFee = 2.8e16; //2.8%

    IERC20 private trustedUnderlying;
    IEToken public override eToken;
    string public override underlyingTokenName;

    IAuditor public auditor;
    IInterestRateModel public interestRateModel;

    // Total deposits in all maturities
    uint256 public override totalMpDeposits;
    mapping(address => uint256) public override totalMpDepositsUser;

    // Total borrows in all maturities
    uint256 public override totalMpBorrows;
    mapping(address => uint256) public override totalMpBorrowsUser;

    /**
     * @notice Event emitted when a user borrows amount of an asset from a
     *         certain maturity date
     * @param to address which borrowed the asset
     * @param amount of the asset that it was borrowed
     * @param commission is the amount extra that it will need to be paid at
     *                   maturity
     * @param maturityDate dateID/poolID/maturity in which the user will have
     *                     to repay the loan
     */
    event BorrowFromMaturityPool(
        address indexed to,
        uint256 amount,
        uint256 commission,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted when a user deposits an amount of an asset to a
     *         certain maturity date collecting a commission at the end of the
     *         period
     * @param from address which deposited the asset
     * @param amount of the asset that it was deposited
     * @param commission is the amount extra that it will be collected at maturity
     * @param maturityDate dateID/poolID/maturity in which the user will be able
     *                     to collect his deposit + his commission
     */
    event DepositToMaturityPool(
        address indexed from,
        uint256 amount,
        uint256 commission,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted when a user collects its deposits after maturity
     * @param from address which will be collecting the asset
     * @param amount of the asset that it was deposited
     * @param maturityDate poolID where the user collected its deposits
     */
    event WithdrawFromMaturityPool(
        address indexed from,
        uint256 amount,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted when a user repays its borrows after maturity
     * @param payer address which repaid the previously borrowed amount
     * @param borrower address which had the original debt
     * @param penalty amount paid for penalties
     * @param amountBorrowed of the asset that it was repaid
     * @param maturityDate poolID where the user repaid its borrowed amounts
     */
    event RepayToMaturityPool(
        address indexed payer,
        address indexed borrower,
        uint256 penalty,
        uint256 amountBorrowed,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted when a liquidator repays a debt in a liquidation
     * @param payer address which repaid the previously borrowed amount
     * @param borrower address which had the original debt
     * @param repayAmount amount paid by the liquidator
     * @param maturityDate poolID where the user repaid its borrowed amounts
     */
    event RepayToMaturityPoolLiquidate(
        address indexed payer,
        address indexed borrower,
        uint256 repayAmount,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted when a user's position had a liquidation
     * @param liquidator address which repaid the previously borrowed amount
     * @param borrower address which had the original debt
     * @param repayAmount amount of the asset that it was repaid
     * @param fixedLenderCollateral address of the asset that it was seized
     *                              by the liquidator
     * @param seizedAmount amount seized of the collateral
     * @param maturityDate poolID where the borrower had an uncollaterized position
     */
    event LiquidateBorrow(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        address fixedLenderCollateral,
        uint256 seizedAmount,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted when a user's collateral has been seized
     * @param liquidator address which seized this collateral
     * @param borrower address which had the original debt
     * @param seizedAmount amount seized of the collateral
     * @param maturityDate poolID where the borrower lost the amount of collateral
     */
    event SeizeAsset(
        address liquidator,
        address borrower,
        uint256 seizedAmount,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted reserves have been added to the protocol
     * @param benefactor address added a certain amount to its reserves
     * @param addAmount amount added as reserves as part of the liquidation event
     */
    event AddReserves(address benefactor, uint256 addAmount);

    /**
     * @notice Event emitted when a user contributed to the smart pool
     * @param user address that added a certain amount to the smart pool
     * @param amount amount added to the smart pool
     */
    event DepositToSmartPool(address indexed user, uint256 amount);

    /**
     * @notice Event emitted when a user contributed to the smart pool
     * @param user address that withdrew a certain amount from the smart pool
     * @param amount amount withdrawn to the smart pool
     */
    event WithdrawFromSmartPool(address indexed user, uint256 amount);

    constructor(
        address _tokenAddress,
        string memory _underlyingTokenName,
        address _eTokenAddress,
        address _auditorAddress,
        address _interestRateModelAddress
    ) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        trustedUnderlying = IERC20(_tokenAddress);
        trustedUnderlying.safeApprove(address(this), type(uint256).max);
        underlyingTokenName = _underlyingTokenName;

        auditor = IAuditor(_auditorAddress);
        eToken = IEToken(_eTokenAddress);
        interestRateModel = IInterestRateModel(_interestRateModelAddress);
    }

    /**
     * @dev Lends to a wallet for a certain maturity date/pool
     * @param amount amount to send to the msg.sender
     * @param maturityDate maturity date for repayment
     */
    function borrowFromMaturityPool(uint256 amount, uint256 maturityDate)
        external
        override
        nonReentrant
    {
        bool newDebt = false;

        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        auditor.requirePoolState(maturityDate, TSUtils.State.VALID);
        PoolLib.MaturityPool memory pool = maturityPools[maturityDate];

        pool.borrowed = pool.borrowed + amount;
        if (amount > pool.available) {
            uint256 smartPoolAvailable = smartPool.supplied -
                smartPool.borrowed;

            if (amount - pool.available > smartPoolAvailable) {
                revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
            }

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
        auditor.beforeBorrowMP(
            address(this),
            msg.sender,
            totalBorrow,
            maturityDate
        );

        pool.borrowed = pool.borrowed + commission;
        maturityPools[maturityDate] = pool;

        uint256 currentTotalBorrow = amount + commission;
        mpUserBorrowedAmount[maturityDate][msg.sender] += currentTotalBorrow;

        totalMpBorrows += currentTotalBorrow;
        totalMpBorrowsUser[msg.sender] += currentTotalBorrow;

        trustedUnderlying.safeTransferFrom(address(this), msg.sender, amount);

        emit BorrowFromMaturityPool(
            msg.sender,
            amount,
            commission,
            maturityDate
        );
    }

    /**
     * @dev Deposits a certain amount to the protocol for
     *      a certain maturity date/pool
     * @param amount amount to receive from the msg.sender
     * @param maturityDate maturity date / pool ID
     */
    function depositToMaturityPool(uint256 amount, uint256 maturityDate)
        external
        override
        nonReentrant
    {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        PoolLib.MaturityPool memory pool = maturityPools[maturityDate];

        // reverts on failure
        auditor.beforeDepositMP(address(this), msg.sender, maturityDate);

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

        maturityPools[maturityDate] = pool;

        uint256 commissionRate = interestRateModel.getRateToSupply(
            maturityDate,
            pool
        );

        uint256 commission = amount.mul_(commissionRate);
        uint256 currentTotalDeposit = amount + commission;
        mpUserSuppliedAmount[maturityDate][msg.sender] += currentTotalDeposit;

        totalMpDeposits += currentTotalDeposit;
        totalMpDepositsUser[msg.sender] += currentTotalDeposit;

        trustedUnderlying.safeTransferFrom(msg.sender, address(this), amount);

        emit DepositToMaturityPool(
            msg.sender,
            amount,
            commission,
            maturityDate
        );
    }

    /**
     * @notice User collects a certain amount of underlying asset after having
     *         supplied tokens until a certain maturity date
     * @dev The pool that the user is trying to retrieve the money should be matured
     * @param redeemer The address of the account which is redeeming the tokens
     * @param redeemAmount The number of underlying tokens to receive
     * @param maturityDate The matured date for which we're trying to retrieve the funds
     */
    function withdrawFromMaturityPool(
        address payable redeemer,
        uint256 redeemAmount,
        uint256 maturityDate
    ) external override nonReentrant {
        if (redeemAmount == 0) {
            revert GenericError(ErrorCode.REDEEM_CANT_BE_ZERO);
        }

        // reverts on failure
        auditor.beforeWithdrawMP(
            address(this),
            redeemer,
            redeemAmount,
            maturityDate
        );

        mpUserSuppliedAmount[maturityDate][redeemer] -= redeemAmount;
        totalMpDeposits -= redeemAmount;
        totalMpDepositsUser[redeemer] -= redeemAmount;

        require(
            trustedUnderlying.balanceOf(address(this)) >= redeemAmount,
            "Not enough liquidity"
        );

        trustedUnderlying.safeTransferFrom(
            address(this),
            redeemer,
            redeemAmount
        );

        emit WithdrawFromMaturityPool(redeemer, redeemAmount, maturityDate);
    }

    /**
     * @notice Sender repays borrower's debt for a maturity date
     * @dev The pool that the user is trying to repay to should be matured
     * @param borrower The address of the account that has the debt
     * @param maturityDate The matured date where the debt is located
     */
    function repayToMaturityPool(address borrower, uint256 maturityDate)
        external
        override
        nonReentrant
    {
        // reverts on failure
        auditor.beforeRepayMP(address(this), borrower);

        // the commission is included
        uint256 amountBorrowed = mpUserBorrowedAmount[maturityDate][borrower];
        (, uint256 amountOwed) = getAccountSnapshot(borrower, maturityDate);

        trustedUnderlying.safeTransferFrom(
            msg.sender,
            address(this),
            amountOwed
        );
        totalMpBorrows -= amountBorrowed;
        totalMpBorrowsUser[borrower] -= amountBorrowed;

        uint256 penalty = amountOwed - amountBorrowed;

        eToken.accrueEarnings(penalty);

        delete mpUserBorrowedAmount[maturityDate][borrower];

        emit RepayToMaturityPool(
            msg.sender,
            borrower,
            penalty,
            amountBorrowed,
            maturityDate
        );
    }

    /**
     * @notice Function to liquidate an uncollaterized position
     * @dev Msg.sender liquidates a borrower's position and repays a certain amount of collateral
     *      for a maturity date, seizing a part of borrower's collateral
     * @param borrower wallet that has an outstanding debt for a certain maturity date
     * @param repayAmount amount to be repaid by liquidator(msg.sender)
     * @param fixedLenderCollateral address of fixedLender from which the collateral will be seized to give the liquidator
     * @param maturityDate maturity date for which the position will be liquidated
     */
    function liquidate(
        address borrower,
        uint256 repayAmount,
        IFixedLender fixedLenderCollateral,
        uint256 maturityDate
    ) external override nonReentrant returns (uint256) {
        return
            _liquidate(
                msg.sender,
                borrower,
                repayAmount,
                fixedLenderCollateral,
                maturityDate
            );
    }

    /**
     * @notice Public function to seize a certain amount of tokens
     * @dev Public function for liquidator to seize borrowers tokens in a certain maturity date.
     *      This function will only be called from another FixedLender, on `liquidation` calls.
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
        // reverts on failure
        auditor.seizeAllowed(
            address(this),
            msg.sender,
            liquidator,
            borrower,
            maturityDate
        );

        _seize(liquidator, borrower, seizeAmount, maturityDate);
    }

    /**
     * @dev Deposits an `amount` of underlying asset into the smart pool, receiving in return overlying eTokens.
     * - E.g. User deposits 100 USDC and gets in return 100 eUSDC
     * @param amount The amount to be deposited
     */
    function depositToSmartPool(uint256 amount) external override {
        auditor.beforeSupplySP(address(this), msg.sender);

        trustedUnderlying.safeTransferFrom(msg.sender, address(this), amount);

        eToken.mint(msg.sender, amount);

        smartPool.supplied += amount;
        emit DepositToSmartPool(msg.sender, amount);
    }

    /**
     * @dev Withdraws an `amount` of underlying asset from the smart pool, burning the equivalent eTokens owned
     * - E.g. User has 100 eUSDC, calls withdraw() and receives 100 USDC, burning the 100 eUSDC
     * @param amount The underlying amount to be withdrawn
     * - Send the value type(uint256).max in order to withdraw the whole eToken balance
     */
    function withdrawFromSmartPool(uint256 amount) external override {
        auditor.beforeWithdrawSP(address(this), msg.sender);

        uint256 userBalance = eToken.balanceOf(msg.sender);
        uint256 amountToWithdraw = amount;
        if (amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }

        if (smartPool.supplied - amountToWithdraw < smartPool.borrowed) {
            revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
        }

        eToken.burn(msg.sender, amountToWithdraw);
        trustedUnderlying.safeTransferFrom(
            address(this),
            msg.sender,
            amountToWithdraw
        );

        smartPool.supplied -= amountToWithdraw;
        emit WithdrawFromSmartPool(msg.sender, amount);
    }

    /**
     * @dev Sets the protocol's liquidation fee for the underlying asset of this fixedLender
     * @param _liquidationFee fee that the protocol earns when position is liquidated
     */
    function setLiquidationFee(uint256 _liquidationFee)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        liquidationFee = _liquidationFee;
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

        uint256 debt = mpUserBorrowedAmount[maturityDate][who];
        uint256 daysDelayed = TSUtils.daysPast(maturityDate);
        if (daysDelayed > 0) {
            debt += debt.mul_(daysDelayed * interestRateModel.penaltyRate());
        }

        return (mpUserSuppliedAmount[maturityDate][who], debt);
    }

    /**
     * @dev Gets the total amount of borrowed money for a maturityDate
     * @param maturityDate maturity date
     */
    function getTotalMpBorrows(uint256 maturityDate)
        public
        view
        override
        returns (uint256)
    {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }
        return maturityPools[maturityDate].borrowed;
    }

    /**
     * @dev Gets the auditor contract interface being used to validate positions
     */
    function getAuditor() public view override returns (IAuditor) {
        return IAuditor(auditor);
    }

    /**
     * @notice This function allows to partially repay a position on liquidation
     * @dev repay function on liquidation, it allows to partially pay debt and it
     *      doesn't call `beforeRepayMP` on the auditor. It should be called after
     *      liquidateAllowed
     * @param payer the address of the account that will pay the debt
     * @param borrower the address of the account that has the debt
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

        uint256 amountBorrowed = mpUserBorrowedAmount[maturityDate][borrower];
        (, uint256 amountOwed) = getAccountSnapshot(borrower, maturityDate);

        // We calculate the amount of the debt this covers, paying proportionally
        // the amount of interests on the overdue debt. If repay amount = amount owed,
        // then amountBorrowed is what should be discounted to the users account
        uint256 debtCovered = (repayAmount * amountBorrowed) / amountOwed;
        eToken.accrueEarnings(repayAmount - debtCovered);
        mpUserBorrowedAmount[maturityDate][borrower] =
            amountBorrowed -
            debtCovered;

        // That repayment diminishes debt in the pool
        PoolLib.MaturityPool memory pool = maturityPools[maturityDate];
        pool.borrowed -= debtCovered;
        maturityPools[maturityDate] = pool;

        totalMpBorrows -= debtCovered;
        totalMpBorrowsUser[borrower] -= debtCovered;

        emit RepayToMaturityPoolLiquidate(
            payer,
            borrower,
            repayAmount,
            maturityDate
        );
    }

    /**
     * @notice Internal Function to liquidate an uncollaterized position
     * @dev Liquidator liquidates a borrower's position and repays a certain amount of collateral
     *      for a maturity date, seizing a part of borrower's collateral
     * @param borrower wallet that has an outstanding debt for a certain maturity date
     * @param repayAmount amount to be repaid by liquidator(msg.sender)
     * @param fixedLenderCollateral address of fixedLender from which the collateral will be seized to give the liquidator
     * @param maturityDate maturity date for which the position will be liquidated
     */
    function _liquidate(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        IFixedLender fixedLenderCollateral,
        uint256 maturityDate
    ) internal returns (uint256) {
        // reverts on failure
        auditor.liquidateAllowed(
            address(this),
            address(fixedLenderCollateral),
            liquidator,
            borrower,
            repayAmount,
            maturityDate
        );

        _repayLiquidate(liquidator, borrower, repayAmount, maturityDate);

        // reverts on failure
        uint256 seizeTokens = auditor.liquidateCalculateSeizeAmount(
            address(this),
            address(fixedLenderCollateral),
            repayAmount
        );

        /* Revert if borrower collateral token balance < seizeTokens */
        (uint256 balance, ) = fixedLenderCollateral.getAccountSnapshot(
            borrower,
            maturityDate
        );
        if (balance < seizeTokens) {
            revert GenericError(ErrorCode.TOKENS_MORE_THAN_BALANCE);
        }

        // If this is also the collateral
        // run seizeInternal to avoid re-entrancy, otherwise make an external call
        // both revert on failure
        if (address(fixedLenderCollateral) == address(this)) {
            _seize(liquidator, borrower, seizeTokens, maturityDate);
        } else {
            fixedLenderCollateral.seize(
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
            address(fixedLenderCollateral),
            seizeTokens,
            maturityDate
        );

        return repayAmount;
    }

    /**
     * @notice Private function to seize a certain amount of tokens
     * @dev Private function for liquidator to seize borrowers tokens in a certain maturity date.
     *      This function will only be called from this FixedLender, on `liquidation` or through `seize`
     *      calls from another FixedLender.
     * @param liquidator address which will receive the seized tokens
     * @param borrower address from which the tokens will be seized
     * @param seizeAmount amount to be removed from borrower's posession
     * @param maturityDate maturity date from where the tokens will be removed. Used to remove liquidity.
     */
    function _seize(
        address liquidator,
        address borrower,
        uint256 seizeAmount,
        uint256 maturityDate
    ) internal {
        uint256 protocolAmount = seizeAmount.mul_(liquidationFee);
        uint256 amountToTransfer = seizeAmount - protocolAmount;

        mpUserSuppliedAmount[maturityDate][borrower] -= seizeAmount;

        // That seize amount diminishes liquidity in the pool
        PoolLib.MaturityPool memory pool = maturityPools[maturityDate];
        pool.supplied -= seizeAmount;
        maturityPools[maturityDate] = pool;

        totalMpDeposits -= seizeAmount;
        totalMpDepositsUser[borrower] -= seizeAmount;

        trustedUnderlying.safeTransfer(liquidator, amountToTransfer);

        emit SeizeAsset(liquidator, borrower, seizeAmount, maturityDate);
        emit AddReserves(address(this), protocolAmount);
    }
}
