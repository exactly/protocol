// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "./EToken.sol";
import "./interfaces/IFixedLender.sol";
import "./interfaces/IAuditor.sol";
import "./interfaces/IEToken.sol";
import "./interfaces/IInterestRateModel.sol";
import "./utils/TSUtils.sol";
import "./utils/DecimalMath.sol";
import "./utils/Errors.sol";

contract FixedLender is IFixedLender, ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;
    using PoolLib for PoolLib.MaturityPool;
    using DecimalMath for uint256;

    mapping(uint256 => mapping(address => uint256)) public mpUserSuppliedAmount;
    mapping(uint256 => mapping(address => uint256)) public mpUserBorrowedAmount;
    mapping(address => uint256[]) public userMpBorrowed;
    mapping(uint256 => PoolLib.MaturityPool) public maturityPools;
    uint256 public smartPoolBorrowed;
    uint256 private liquidationFee = 2.8e16; //2.8%
    uint256 private protocolFee; // 0%
    uint256 public protocolEarnings;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public override trustedUnderlying;
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
     * @param debtCovered amount of the debt that it was covered in this repayment
     * @param maturityDate poolID where the user repaid its borrowed amounts
     */
    event RepayToMaturityPool(
        address indexed payer,
        address indexed borrower,
        uint256 penalty,
        uint256 debtCovered,
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
     */
    event SeizeAsset(
        address liquidator,
        address borrower,
        uint256 seizedAmount
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
     * @param maxAmountAllowed maximum amount of debt that
     *        the user is willing to accept for the transaction
     *        to go through
     */
    function borrowFromMaturityPool(
        uint256 amount,
        uint256 maturityDate,
        uint256 maxAmountAllowed
    ) external override nonReentrant whenNotPaused {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        uint256 smartPoolSupply = eToken.totalSupply();
        uint256 maxDebt = smartPoolSupply / auditor.maxFuturePools();

        smartPoolBorrowed += maturityPools[maturityDate].takeMoney(
            amount,
            maxDebt
        );

        PoolLib.MaturityPool memory pool = maturityPools[maturityDate];

        uint256 commissionRate = interestRateModel.getRateToBorrow(
            maturityDate,
            pool,
            smartPoolBorrowed,
            smartPoolSupply,
            true
        );
        uint256 commission = amount.mul_(commissionRate);

        if (amount + commission > maxAmountAllowed) {
            revert GenericError(ErrorCode.TOO_MUCH_SLIPPAGE);
        }

        uint256 totalBorrow = amount + commission;
        // reverts on failure
        auditor.beforeBorrowMP(
            address(this),
            msg.sender,
            totalBorrow,
            maturityDate
        );
        if (mpUserBorrowedAmount[maturityDate][msg.sender] == 0) {
            userMpBorrowed[msg.sender].push(maturityDate);
        }

        maturityPools[maturityDate].addFee(maturityDate, commission);

        mpUserBorrowedAmount[maturityDate][msg.sender] += totalBorrow;
        totalMpBorrows += totalBorrow;
        totalMpBorrowsUser[msg.sender] += totalBorrow;

        trustedUnderlying.safeTransfer(msg.sender, amount);

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
     * @param minAmountRequired minimum amount of capital required
     *        by the depositor for the transaction to be accepted
     */
    function depositToMaturityPool(
        uint256 amount,
        uint256 maturityDate,
        uint256 minAmountRequired
    ) external override nonReentrant whenNotPaused {
        // reverts on failure
        auditor.beforeDepositMP(address(this), msg.sender, maturityDate);

        amount = doTransferIn(msg.sender, amount);

        uint256 commission = maturityPools[maturityDate].addMoney(
            maturityDate,
            amount
        );

        if (amount + commission < minAmountRequired) {
            revert GenericError(ErrorCode.TOO_MUCH_SLIPPAGE);
        }

        uint256 currentTotalDeposit = amount + commission;
        mpUserSuppliedAmount[maturityDate][msg.sender] += currentTotalDeposit;
        totalMpDeposits += currentTotalDeposit;
        totalMpDepositsUser[msg.sender] += currentTotalDeposit;

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
        auditor.beforeWithdrawMP(address(this), redeemer, maturityDate);

        uint256 maxDebt = eToken.totalSupply() / auditor.maxFuturePools();
        smartPoolBorrowed += maturityPools[maturityDate].takeMoney(
            redeemAmount,
            maxDebt
        );

        mpUserSuppliedAmount[maturityDate][redeemer] -= redeemAmount;
        totalMpDeposits -= redeemAmount;
        totalMpDepositsUser[redeemer] -= redeemAmount;

        require(
            trustedUnderlying.balanceOf(address(this)) >= redeemAmount,
            "Not enough liquidity"
        );

        trustedUnderlying.safeTransfer(redeemer, redeemAmount);

        emit WithdrawFromMaturityPool(redeemer, redeemAmount, maturityDate);
    }

    /**
     * @notice Sender repays an amount of borrower's debt for a maturity date
     * @dev The pool that the user is trying to repay to should be matured
     * @param borrower The address of the account that has the debt
     * @param maturityDate The matured date where the debt is located
     * @param repayAmount amount to be paid for the borrower's debt
     */
    function repayToMaturityPool(
        address borrower,
        uint256 maturityDate,
        uint256 repayAmount
    ) external override nonReentrant whenNotPaused {
        // reverts on failure
        auditor.beforeRepayMP(address(this), borrower, maturityDate);

        _repay(msg.sender, borrower, repayAmount, maturityDate);
    }

    /**
     * @notice Function to liquidate an uncollaterized position
     * @dev Msg.sender liquidates a borrower's position and repays a certain amount of debt
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
    ) external override nonReentrant whenNotPaused returns (uint256) {
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
     * @notice public function to transfer funds from protocol earnings to a specified wallet
     * @param who address which will receive the funds
     * @param amount amount to be transfered
     */
    function withdrawEarnings(address who, uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        protocolEarnings -= amount;
        trustedUnderlying.safeTransferFrom(address(this), who, amount);
    }

    /**
     * @notice Public function to seize a certain amount of tokens
     * @dev Public function for liquidator to seize borrowers tokens in the smart pool.
     *      This function will only be called from another FixedLender, on `liquidation` calls.
     *      That's why msg.sender needs to be passed to the private function (to be validated as a market)
     * @param liquidator address which will receive the seized tokens
     * @param borrower address from which the tokens will be seized
     * @param seizeAmount amount to be removed from borrower's posession
     */
    function seize(
        address liquidator,
        address borrower,
        uint256 seizeAmount
    ) external override nonReentrant whenNotPaused {
        _seize(msg.sender, liquidator, borrower, seizeAmount);
    }

    /**
     * @dev Deposits an `amount` of underlying asset into the smart pool, receiving in return overlying eTokens.
     * - E.g. User deposits 100 USDC and gets in return 100 eUSDC
     * @param amount The amount to be deposited
     */
    function depositToSmartPool(uint256 amount)
        external
        override
        whenNotPaused
    {
        auditor.beforeDepositSP(address(this), msg.sender);
        amount = doTransferIn(msg.sender, amount);
        eToken.mint(msg.sender, amount);
        emit DepositToSmartPool(msg.sender, amount);
    }

    /**
     * @dev Withdraws an `amount` of underlying asset from the smart pool, burning the equivalent eTokens owned
     * - E.g. User has 100 eUSDC, calls withdraw() and receives 100 USDC, burning the 100 eUSDC
     * @param amount The underlying amount to be withdrawn
     * - Send the value type(uint256).max in order to withdraw the whole eToken balance
     */
    function withdrawFromSmartPool(uint256 amount) external override {
        auditor.beforeWithdrawSP(address(this), msg.sender, amount);

        uint256 userBalance = eToken.balanceOf(msg.sender);
        uint256 amountToWithdraw = amount;
        if (amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }

        // We check if the underlying liquidity that the user wants to withdraw is borrowed
        if (eToken.totalSupply() - amountToWithdraw < smartPoolBorrowed) {
            revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
        }

        eToken.burn(msg.sender, amountToWithdraw);
        trustedUnderlying.safeTransfer(msg.sender, amountToWithdraw);

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
     * @dev Sets the protocol's fee for revenues
     * @param _protocolFee that the protocol earns when position is liquidated
     */
    function setProtocolFee(uint256 _protocolFee)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        protocolFee = _protocolFee;
    }

    /**
     * @dev Sets the _pause state to true in case of emergency, triggered by an authorized account
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Sets the _pause state to false when threat is gone, triggered by an authorized account
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Gets current snapshot for a wallet in certain maturity
     * @param who wallet to return status snapshot in the specified maturity date
     * @param maturityDate maturityDate
     * - Send the value 0 in order to get the snapshot for all maturities where the user borrowed
     * @return the amount the user deposited to the smart pool and the total money he owes from maturities
     */
    function getAccountSnapshot(address who, uint256 maturityDate)
        public
        view
        override
        returns (uint256, uint256)
    {
        uint256 debt;
        if (maturityDate == 0) {
            for (uint256 i = 0; i < userMpBorrowed[who].length; i++) {
                debt += getAccountDebt(who, userMpBorrowed[who][i]);
            }
        } else {
            debt = getAccountDebt(who, maturityDate);
        }

        return (eToken.balanceOf(who), debt);
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
     * @notice This function allows to (partially) repay a position
     * @dev Internal repay function, it allows to partially pay debt and it
     *      should be called after `beforeRepayMP` or `liquidateAllowed`
     *      on the auditor
     * @param payer the address of the account that will pay the debt
     * @param borrower the address of the account that has the debt
     * @param repayAmount the amount of debt of the pool that should be paid
     * @param maturityDate the maturityDate to access the pool
     * @return the actual amount that it was transferred into the protocol
     */
    function _repay(
        address payer,
        address borrower,
        uint256 repayAmount,
        uint256 maturityDate
    ) internal returns (uint256) {
        if (repayAmount == 0) {
            revert GenericError(ErrorCode.REPAY_ZERO);
        }

        repayAmount = doTransferIn(payer, repayAmount);
        (, uint256 amountOwed) = getAccountSnapshot(borrower, maturityDate);

        if (repayAmount > amountOwed) {
            revert GenericError(ErrorCode.TOO_MUCH_REPAY_TRANSFER);
        }

        uint256 amountBorrowed = mpUserBorrowedAmount[maturityDate][borrower];

        // We calculate the amount of the debt this covers, paying proportionally
        // the amount of interests on the overdue debt. If repay amount = amount owed,
        // then amountBorrowed is what should be discounted to the users account
        uint256 debtCovered = (repayAmount * amountBorrowed) / amountOwed;
        uint256 penalties = repayAmount - debtCovered;

        mpUserBorrowedAmount[maturityDate][borrower] =
            amountBorrowed -
            debtCovered;
            
        if (mpUserBorrowedAmount[maturityDate][borrower] == 0) {
            uint256[] memory userMaturitiesBorrowedList = userMpBorrowed[
                borrower
            ];
            uint256 len = userMaturitiesBorrowedList.length;
            uint256 maturityIndex = len;
            for (uint256 i = 0; i < len; i++) {
                if (userMaturitiesBorrowedList[i] == maturityDate) {
                    maturityIndex = i;
                    break;
                }
            }

            // We *must* have found the maturity in the list or our redundant data structure is broken
            assert(maturityIndex < len);

            // copy last item in list to location of item to be removed, reduce length by 1
            uint256[] storage storedList = userMpBorrowed[borrower];
            storedList[maturityIndex] = storedList[storedList.length - 1];
            storedList.pop();
        }


        // Pays back in the following order:
        //       1) Maturity Pool Depositors
        //       2) Smart Pool Debt
        //       3) Earnings Smart Pool the rest
        (
            uint256 smartPoolDebtReduction,
            uint256 fee,
            uint256 earningsRepay
        ) = maturityPools[maturityDate].repay(maturityDate, repayAmount);

        // We take a share of the spread of the protocol
        uint256 protocolShare = fee.mul_(protocolFee);
        protocolEarnings += protocolShare;
        eToken.accrueEarnings(fee - protocolShare + earningsRepay);

        smartPoolBorrowed -= smartPoolDebtReduction;
        totalMpBorrows -= debtCovered;
        totalMpBorrowsUser[borrower] -= debtCovered;

        emit RepayToMaturityPool(
            payer,
            borrower,
            penalties,
            debtCovered,
            maturityDate
        );

        return repayAmount;
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
            repayAmount
        );

        repayAmount = _repay(liquidator, borrower, repayAmount, maturityDate);

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
            _seize(address(this), liquidator, borrower, seizeTokens);
        } else {
            fixedLenderCollateral.seize(liquidator, borrower, seizeTokens);
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
     * @dev Private function for liquidator to seize borrowers tokens in the smart pool.
     *      This function will only be called from this FixedLender, on `liquidation` or through `seize` calls from another FixedLender.
     *      That's why msg.sender needs to be passed to the private function (to be validated as a market)
     * @param seizerFixedLender address which is calling the seize function (see `seize` public function)
     * @param liquidator address which will receive the seized tokens
     * @param borrower address from which the tokens will be seized
     * @param seizeAmount amount to be removed from borrower's posession
     */
    function _seize(
        address seizerFixedLender,
        address liquidator,
        address borrower,
        uint256 seizeAmount
    ) internal {
        // reverts on failure
        auditor.seizeAllowed(
            address(this),
            seizerFixedLender,
            liquidator,
            borrower
        );

        uint256 protocolAmount = seizeAmount.mul_(liquidationFee);
        uint256 amountToTransfer = seizeAmount - protocolAmount;

        auditor.beforeDepositSP(address(this), borrower);

        // We check if the underlying liquidity that the user wants to seize is borrowed
        if (eToken.totalSupply() - amountToTransfer < smartPoolBorrowed) {
            revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
        }

        // That seize amount diminishes liquidity in the pool
        eToken.burn(borrower, seizeAmount);
        trustedUnderlying.safeTransfer(liquidator, amountToTransfer);

        emit SeizeAsset(liquidator, borrower, seizeAmount);
        emit AddReserves(address(this), protocolAmount);
    }

    /**
     * @notice Private function to safely transfer funds into this contract
     * @dev Some underlying token implementations can alter the transfer function to
     *      transfer less of the initial amount (ie: take a commission out).
     *      This function takes into account this scenario
     * @param from address which will transfer funds in (approve needed on underlying token)
     * @param amount amount to be transfered
     * @return amount actually transferred by the protocol
     */
    function doTransferIn(address from, uint256 amount)
        internal
        returns (uint256)
    {
        uint256 balanceBefore = trustedUnderlying.balanceOf(address(this));
        trustedUnderlying.safeTransferFrom(from, address(this), amount);

        // Calculate the amount that was *actually* transferred
        uint256 balanceAfter = trustedUnderlying.balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    /**
     * @notice Internal function to get the debt + penalties of an account for a certain maturityDate
     * @param who wallet to return debt status for the specified maturityDate
     * @param maturityDate amount to be transfered
     * @return the total owed denominated in number of tokens
     */
    function getAccountDebt(address who, uint256 maturityDate)
        internal
        view
        returns (uint256)
    {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        uint256 debt = mpUserBorrowedAmount[maturityDate][who];
        uint256 daysDelayed = TSUtils.daysPre(maturityDate, block.timestamp);
        if (daysDelayed > 0) {
            debt += debt.mul_(daysDelayed * interestRateModel.penaltyRate());
        }

        return debt;
    }
}
