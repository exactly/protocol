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
import "./interfaces/IPoolAccounting.sol";
import "./utils/DecimalMath.sol";
import "./utils/TSUtils.sol";
import "./utils/Errors.sol";

contract FixedLender is IFixedLender, ReentrancyGuard, AccessControl, Pausable {
    using DecimalMath for uint256;

    uint256 public protocolSpreadFee = 2.8e16; // 2.8%
    uint256 public protocolLiquidationFee = 2.8e16; // 2.8%
    uint8 public constant MAX_FUTURE_POOLS = 12; // if every 14 days, then 6 months
    uint256 public treasury;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public override trustedUnderlying;
    IEToken public override eToken;
    string public override underlyingTokenName;
    IPoolAccounting public poolAccounting;

    IAuditor public auditor;

    // Total borrows in all maturities
    uint256 public override totalMpBorrows;

    /**
     * @notice Event emitted when a user borrows amount of an asset from a
     *         certain maturity date
     * @param to address which borrowed the asset
     * @param amount of the asset that it was borrowed
     * @param fee amount extra that it will need to be paid at maturity
     * @param maturityDate dateID/poolID/maturity in which the user will have
     *                     to repay the loan
     */
    event BorrowFromMaturityPool(
        address indexed to,
        uint256 amount,
        uint256 fee,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted when a user deposits an amount of an asset to a
     *         certain maturity date collecting a fee at the end of the
     *         period
     * @param from address which deposited the asset
     * @param amount of the asset that it was deposited
     * @param fee is the extra amount that it will be collected at maturity
     * @param maturityDate dateID/poolID/maturity in which the user will be able
     *                     to collect his deposit + his fee
     */
    event DepositToMaturityPool(
        address indexed from,
        uint256 amount,
        uint256 fee,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted when a user collects its deposits after maturity
     * @param from address which will be collecting the asset
     * @param amount of the asset that it was deposited
     * @param amountDiscounted of the asset that it was deposited (in case of early withdrawal)
     * @param maturityDate poolID where the user collected its deposits
     */
    event WithdrawFromMaturityPool(
        address indexed from,
        uint256 amount,
        uint256 amountDiscounted,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted when a user repays its borrows after maturity
     * @param payer address which repaid the previously borrowed amount
     * @param borrower address which had the original debt
     * @param repayAmount amount that was repaid
     * @param debtCovered amount of the debt that was covered in this repayment (penalties could have been repaid)
     * @param maturityDate poolID where the user repaid its borrowed amounts
     */
    event RepayToMaturityPool(
        address indexed payer,
        address indexed borrower,
        uint256 repayAmount,
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
        address _poolAccounting
    ) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        trustedUnderlying = IERC20(_tokenAddress);
        underlyingTokenName = _underlyingTokenName;

        auditor = IAuditor(_auditorAddress);
        eToken = IEToken(_eTokenAddress);
        poolAccounting = IPoolAccounting(_poolAccounting);
    }

    /**
     * @dev Sets the protocol's spread fee used on loan repayment
     * @param _protocolSpreadFee percentage amount represented with 1e18 decimals
     */
    function setProtocolSpreadFee(uint256 _protocolSpreadFee)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        protocolSpreadFee = _protocolSpreadFee;
    }

    /**
     * @dev Sets the protocol's collateral liquidation fee used on liquidations
     * @param _protocolLiquidationFee percentage amount represented with 1e18 decimals
     */
    function setProtocolLiquidationFee(uint256 _protocolLiquidationFee)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        protocolLiquidationFee = _protocolLiquidationFee;
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

    /** @notice Function to liquidate an uncollaterized position
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
        uint256 maxAmountAllowed,
        IFixedLender fixedLenderCollateral,
        uint256 maturityDate
    ) external override nonReentrant whenNotPaused returns (uint256) {
        return
            _liquidate(
                msg.sender,
                borrower,
                repayAmount,
                maxAmountAllowed,
                fixedLenderCollateral,
                maturityDate
            );
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
     * @dev Function to retrieve valid future pools
     */
    function getFuturePools() external view returns (uint256[] memory) {
        return TSUtils.futurePools(MAX_FUTURE_POOLS);
    }

    /**
     * @notice public function to transfer funds from protocol earnings to a specified wallet
     * @param who address which will receive the funds
     * @param amount amount to be transferred
     */
    function withdrawFromTreasury(address who, uint256 amount)
        public
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        treasury -= amount;
        SafeERC20.safeTransfer(trustedUnderlying, who, amount);
    }

    /**
     * @dev Withdraws an `amount` of underlying asset from the smart pool, burning the equivalent eTokens owned
     * - E.g. User has 100 eUSDC, calls withdraw() and receives 100 USDC, burning the 100 eUSDC
     * @param amount The underlying amount to be withdrawn
     * - Send the value type(uint256).max in order to withdraw the whole eToken balance
     */
    function withdrawFromSmartPool(uint256 amount) public override {
        // reverts on failure
        auditor.validateAccountShortfall(address(this), msg.sender, amount);

        uint256 userBalance = eToken.balanceOf(msg.sender);
        uint256 amountToWithdraw = amount;
        if (amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }

        // We check if the underlying liquidity that the user wants to withdraw is borrowed
        if (
            eToken.totalSupply() - amountToWithdraw <
            poolAccounting.smartPoolBorrowed()
        ) {
            revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
        }

        eToken.burn(msg.sender, amountToWithdraw);
        doTransferOut(msg.sender, amountToWithdraw);

        emit WithdrawFromSmartPool(msg.sender, amount);
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
    ) public override nonReentrant whenNotPaused {
        // reverts on failure
        TSUtils.validateRequiredPoolState(
            MAX_FUTURE_POOLS,
            maturityDate,
            TSUtils.State.VALID,
            TSUtils.State.NONE
        );

        (
            uint256 totalOwed,
            uint256 earningsSP,
            uint256 earningsTreasury
        ) = poolAccounting.borrowMP(
                maturityDate,
                msg.sender,
                amount,
                maxAmountAllowed,
                eToken.totalSupply(),
                MAX_FUTURE_POOLS
            );
        totalMpBorrows += totalOwed;

        treasury += earningsTreasury;
        eToken.accrueEarnings(earningsSP);
        auditor.validateBorrowMP(address(this), msg.sender);

        doTransferOut(msg.sender, amount);

        emit BorrowFromMaturityPool(
            msg.sender,
            amount,
            totalOwed - amount, // fee
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
    ) public override nonReentrant whenNotPaused {
        // reverts on failure
        TSUtils.validateRequiredPoolState(
            MAX_FUTURE_POOLS,
            maturityDate,
            TSUtils.State.VALID,
            TSUtils.State.NONE
        );

        amount = doTransferIn(msg.sender, amount);

        (uint256 currentTotalDeposit, uint256 earningsSP) = poolAccounting
            .depositMP(maturityDate, msg.sender, amount, minAmountRequired);

        eToken.accrueEarnings(earningsSP);

        emit DepositToMaturityPool(
            msg.sender,
            amount,
            currentTotalDeposit - amount,
            maturityDate
        );
    }

    /**
     * @notice User collects a certain amount of underlying asset after having
     *         supplied tokens until a certain maturity date
     * @dev The pool that the user is trying to retrieve the money should be matured
     * @param redeemer The address of the account which is redeeming the tokens
     * @param redeemAmount The number of underlying tokens to receive
     * @param minAmountRequired minimum amount required by the user (if penalty fees for early withdrawal)
     * @param maturityDate The matured date for which we're trying to retrieve the funds
     */
    function withdrawFromMaturityPool(
        address payable redeemer,
        uint256 redeemAmount,
        uint256 minAmountRequired,
        uint256 maturityDate
    ) public override nonReentrant {
        if (redeemAmount == 0) {
            revert GenericError(ErrorCode.REDEEM_CANT_BE_ZERO);
        }

        // reverts on failure
        TSUtils.validateRequiredPoolState(
            MAX_FUTURE_POOLS,
            maturityDate,
            TSUtils.State.VALID,
            TSUtils.State.MATURED
        );

        // We check if there's any discount to be applied for early withdrawal
        (
            uint256 redeemAmountDiscounted,
            uint256 earningsSP,
            uint256 earningsTreasury
        ) = poolAccounting.withdrawMP(
                maturityDate,
                redeemer,
                redeemAmount,
                minAmountRequired,
                eToken.totalSupply() / MAX_FUTURE_POOLS
            );

        eToken.accrueEarnings(earningsSP);
        treasury += earningsTreasury;

        doTransferOut(redeemer, redeemAmountDiscounted);

        emit WithdrawFromMaturityPool(
            redeemer,
            redeemAmount,
            redeemAmountDiscounted,
            maturityDate
        );
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
        uint256 repayAmount,
        uint256 maxAmountAllowed
    ) public override nonReentrant whenNotPaused {
        // reverts on failure
        TSUtils.validateRequiredPoolState(
            MAX_FUTURE_POOLS,
            maturityDate,
            TSUtils.State.VALID,
            TSUtils.State.MATURED
        );

        _repay(
            msg.sender,
            borrower,
            maturityDate,
            repayAmount,
            maxAmountAllowed
        );
    }

    /**
     * @dev Deposits an `amount` of underlying asset into the smart pool, receiving in return overlying eTokens.
     * - E.g. User deposits 100 USDC and gets in return 100 eUSDC
     * @param amount The amount to be deposited
     */
    function depositToSmartPool(uint256 amount) public override whenNotPaused {
        amount = doTransferIn(msg.sender, amount);
        eToken.mint(msg.sender, amount);
        emit DepositToSmartPool(msg.sender, amount);
    }

    /**
     * @dev Gets the market size of the smart pool, usefull for dApps to show current status
     */
    function getSmartPoolDeposits() public view returns (uint256) {
        return eToken.totalSupply();
    }

    /**
     * @dev Gets the auditor contract interface being used to validate positions
     */
    function getAuditor() public view override returns (IAuditor) {
        return IAuditor(auditor);
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
        return (
            eToken.balanceOf(who),
            poolAccounting.getAccountBorrows(who, maturityDate)
        );
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
        return poolAccounting.getTotalMpBorrows(maturityDate);
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
        uint256 maturityDate,
        uint256 repayAmount,
        uint256 maxAmountAllowed
    ) internal returns (uint256) {
        if (repayAmount == 0) {
            revert GenericError(ErrorCode.REPAY_ZERO);
        }

        repayAmount = doTransferIn(payer, repayAmount);

        (
            uint256 spareRepayAmount,
            uint256 debtCovered,
            uint256 earningsSP,
            uint256 earningsTreasury
        ) = poolAccounting.repayMP(
                maturityDate,
                borrower,
                repayAmount,
                maxAmountAllowed
            );

        if (spareRepayAmount > 0) {
            doTransferOut(payer, spareRepayAmount);
        }

        eToken.accrueEarnings(earningsSP);
        treasury += earningsTreasury;

        totalMpBorrows -= debtCovered;

        emit RepayToMaturityPool(
            payer,
            borrower,
            repayAmount,
            debtCovered,
            maturityDate
        );

        return repayAmount - spareRepayAmount;
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
        uint256 maxAmountAllowed,
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

        repayAmount = _repay(
            liquidator,
            borrower,
            maturityDate,
            repayAmount,
            maxAmountAllowed
        );

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

        uint256 protocolAmount = seizeAmount.mul_(protocolLiquidationFee);
        uint256 amountToTransfer = seizeAmount - protocolAmount;
        treasury += protocolAmount;

        // We check if the underlying liquidity that the user wants to seize is borrowed
        if (
            eToken.totalSupply() - amountToTransfer <
            poolAccounting.smartPoolBorrowed()
        ) {
            revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
        }

        // That seize amount diminishes liquidity in the pool
        eToken.burn(borrower, seizeAmount);
        doTransferOut(liquidator, amountToTransfer);

        emit SeizeAsset(liquidator, borrower, seizeAmount);
        emit AddReserves(address(this), protocolAmount);
    }

    /**
     * @notice Private function to safely transfer funds into this contract
     * @dev Some underlying token implementations can alter the transfer function to
     *      transfer less of the initial amount (ie: take a fee out).
     *      This function takes into account this scenario
     * @param from address which will transfer funds in (approve needed on underlying token)
     * @param amount amount to be transferred
     * @return amount actually transferred by the protocol
     */
    function doTransferIn(address from, uint256 amount)
        internal
        virtual
        returns (uint256)
    {
        uint256 balanceBefore = trustedUnderlying.balanceOf(address(this));
        SafeERC20.safeTransferFrom(
            trustedUnderlying,
            from,
            address(this),
            amount
        );

        // Calculate the amount that was *actually* transferred
        uint256 balanceAfter = trustedUnderlying.balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    function doTransferOut(address to, uint256 amount) internal virtual {
        SafeERC20.safeTransfer(trustedUnderlying, to, amount);
    }
}
