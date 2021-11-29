// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./interfaces/IFixedLender.sol";
import "./interfaces/IAuditor.sol";
import "./interfaces/IOracle.sol";
import "./utils/TSUtils.sol";
import "./utils/DecimalMath.sol";
import "./utils/Errors.sol";
import "./utils/ExaLib.sol";

contract Auditor is IAuditor, AccessControl {
    using DecimalMath for uint256;
    using SafeCast for uint256;
    using ExaLib for ExaLib.RewardsState;
    using MarketsLib for MarketsLib.Book;

    // Protocol Management
    MarketsLib.Book private book;

    uint256 public closeFactor = 5e17;
    uint256 public liquidationIncentive = 1e18 + 1e17;
    uint8 public maxFuturePools = 12; // if every 14 days, then 6 months
    address[] public marketsAddresses;

    // Rewards Management
    ExaLib.RewardsState public rewardsState;

    IOracle public oracle;

    /**
     * @notice Event emitted when a new market is listed for borrow/lending
     * @param fixedLender address of the fixedLender market that it was listed
     */
    event MarketListed(address fixedLender);

    /**
     * @notice Event emitted when a user enters a market to use his deposit as collateral
     *         for a loan. Notice that the market entered is the pair fixedLender/maturityDate
     * @param fixedLender address of the market that the user entered
     * @param account address of the user that just entered a market
     * @param maturityDate dateID/poolID/maturity that the user just entered
     */
    event MarketEntered(
        address fixedLender,
        address account,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted when a user leaves a market. This means that he would stop using
     *         his deposit as collateral and it won't ask for any loans in this market
     * @param fixedLender address of the market that the user just left
     * @param account address of the user that just left a market
     * @param maturityDate dateID/poolID/maturity that the user just left
     */
    event MarketExited(
        address fixedLender,
        address account,
        uint256 maturityDate
    );

    /**
     * @notice Event emitted when a certain action has been paused by the protocol
     * @param fixedLender address of the market that a certain feature has been paused/re-enabled
     * @param action string describing the action that has been paused/re-enabled
     * @param paused boolean describing if the action has been paused or re-enabled
     */
    event ActionPaused(address fixedLender, string action, bool paused);

    /**
     * @notice Event emitted when a new Oracle has been set
     * @param newOracle address of the new oracle that is used to calculate liquidity
     */
    event OracleChanged(address newOracle);

    /**
     * @notice Event emitted when a new borrow cap has been set for a certain fixedLender
     *         If newBorrowCap is 0, that means that there's no cap
     * @param fixedLender address of the lender that has a new borrow cap
     * @param newBorrowCap new borrow cap expressed with 1e18 precision for the given market.
     *                     0 = means no cap
     */
    event NewBorrowCap(address indexed fixedLender, uint256 newBorrowCap);

    /**
     * @notice Event emitted when a new ExaSpeed has been set for a given fixedLender.
     *         The speed is the amount of EXA tokens that it will be given to
     *         suppliers/borrowers/lenders on each block. Amount distributed accordingly
     *         to their contributions
     * @param fixedLenderAddress address of the lender that has a new borrow cap
     * @param newSpeed new borrow cap expressed with 1e18 precision for the given market.
     */
    event ExaSpeedUpdated(address fixedLenderAddress, uint256 newSpeed);

    /**
     * @notice Event emitted each time EXA has been distributed to a certain user as a maturity pool supplier
     * @param fixedLender address of the fixed lender market in which a user has received rewards
     * @param supplier address of the supplier that have received rewards in a given lender space
     * @param mpSupplierDelta delta blocks that have been processed
     * @param exaMPSupplyIndex index of the given market that was used to update user rewards
     */
    event DistributedMPSupplierExa(
        address indexed fixedLender,
        address indexed supplier,
        uint256 mpSupplierDelta,
        uint256 exaMPSupplyIndex
    );

    /**
     * @notice Event emitted each time EXA has been distributed to a certain user as a maturity pool borrower
     * @param fixedLender address of the fixed lender market in which a user has received rewards
     * @param borrower address of the borrower that have received rewards in a given fixedLender space
     * @param mpBorrowerDelta delta blocks that have been processed
     * @param exaMPBorrowIndex index of the given market that was used to update user rewards
     */
    event DistributedMPBorrowerExa(
        address indexed fixedLender,
        address indexed borrower,
        uint256 mpBorrowerDelta,
        uint256 exaMPBorrowIndex
    );

    /**
     * @notice Event emitted each time EXA has been distributed to a certain user as a smart pool supplier
     * @param fixedLender address of the fixed lender market in which a user has received rewards
     * @param supplier address of the supplier that have received rewards in a given lender space
     * @param spSupplierDelta delta blocks that have been processed
     * @param exaSPSupplyIndex index of the given market that was used to update user rewards
     */
    event DistributedSPSupplierExa(
        address indexed fixedLender,
        address indexed supplier,
        uint256 spSupplierDelta,
        uint256 exaSPSupplyIndex
    );

    constructor(address _priceOracleAddress, address _exaToken) {
        rewardsState.exaToken = _exaToken;
        oracle = IOracle(_priceOracleAddress);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Allows wallet to enter certain markets (fixedLenderDAI, fixedLenderETH, etc)
     *      By performing this action, the wallet's money could be used as collateral
     * @param fixedLenders contracts addresses to enable for `msg.sender` for a certain maturity
     * @param maturityDate poolID in which the fixedLenders will be enabled
     */
    function enterMarkets(address[] calldata fixedLenders, uint256 maturityDate)
        external
    {
        _requirePoolState(maturityDate, TSUtils.State.VALID);
        uint256 len = fixedLenders.length;
        for (uint256 i = 0; i < len; i++) {
            book.addToMarket(fixedLenders[i], msg.sender, maturityDate);
        }
    }

    /**
     * @notice Removes fixedLender from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *      or be providing necessary collateral for an outstanding borrow.
     * @param fixedLenderAddress The address of the asset to be removed
     * @param maturityDate The timestamp/poolID where the user wants to stop providing collateral
     */
    function exitMarket(address fixedLenderAddress, uint256 maturityDate)
        external
    {
        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        IFixedLender fixedLender = IFixedLender(fixedLenderAddress);

        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        (uint256 amountHeld, uint256 borrowBalance) = fixedLender
            .getAccountSnapshot(msg.sender, maturityDate);

        /* Fail if the sender has a borrow balance */
        if (borrowBalance != 0) {
            revert GenericError(ErrorCode.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        _beforeWithdrawMP(
            fixedLenderAddress,
            msg.sender,
            amountHeld,
            maturityDate
        );

        book.exitMarket(fixedLenderAddress, msg.sender, maturityDate);
    }

    /**
     * @dev Function to set Oracle's to be used
     * @param _priceOracleAddress address of the new oracle
     */
    function setOracle(address _priceOracleAddress)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        oracle = IOracle(_priceOracleAddress);
        emit OracleChanged(_priceOracleAddress);
    }

    /**
     * @notice Set liquidation incentive for the whole ecosystem
     * @param _liquidationIncentive new liquidation incentive. It's a factor, so 15% would be 1.15e18
     */
    function setLiquidationIncentive(uint256 _liquidationIncentive)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        liquidationIncentive = _liquidationIncentive;
    }

    /**
     * @notice Set EXA speed for a single market
     * @param fixedLenderAddress The market whose EXA speed to update
     * @param exaSpeed New EXA speed for market
     */
    function setExaSpeed(address fixedLenderAddress, uint256 exaSpeed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        MarketsLib.Market storage market = book.markets[fixedLenderAddress];
        if (market.isListed == false) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        if (
            rewardsState.setExaSpeed(
                block.number,
                fixedLenderAddress,
                exaSpeed
            ) == true
        ) {
            emit ExaSpeedUpdated(fixedLenderAddress, exaSpeed);
        }
    }

    /**
     * @dev Function to enable a certain FixedLender market to be used as collateral
     * @param fixedLender address to add to the protocol
     * @param collateralFactor fixedLender's collateral factor for the underlying asset
     */
    function enableMarket(
        address fixedLender,
        uint256 collateralFactor,
        string memory symbol,
        string memory name,
        uint8 decimals
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MarketsLib.Market storage market = book.markets[fixedLender];

        if (market.isListed) {
            revert GenericError(ErrorCode.MARKET_ALREADY_LISTED);
        }

        if (IFixedLender(fixedLender).getAuditor() != this) {
            revert GenericError(ErrorCode.AUDITOR_MISMATCH);
        }

        market.isListed = true;
        market.collateralFactor = collateralFactor;
        market.symbol = symbol;
        market.name = name;
        market.decimals = decimals;

        marketsAddresses.push(fixedLender);

        emit MarketListed(fixedLender);
    }

    /**
     * @dev Function to pause/unpause borrowing on a certain market
     * @param fixedLender address to pause
     * @param paused true/false
     */
    function pauseBorrow(address fixedLender, bool paused)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bool)
    {
        if (!book.markets[fixedLender].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        book.borrowPaused[address(fixedLender)] = paused;
        emit ActionPaused(fixedLender, "Borrow", paused);
        return paused;
    }

    /**
     * @notice Set the given borrow caps for the given fixedLender markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @param fixedLenders The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function setMarketBorrowCaps(
        address[] calldata fixedLenders,
        uint256[] calldata newBorrowCaps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 numMarkets = fixedLenders.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        if (numMarkets == 0 || numMarkets != numBorrowCaps) {
            revert GenericError(ErrorCode.INVALID_SET_BORROW_CAP);
        }

        for (uint256 i = 0; i < numMarkets; i++) {
            if (!book.markets[fixedLenders[i]].isListed) {
                revert GenericError(ErrorCode.MARKET_NOT_LISTED);
            }

            book.borrowCaps[fixedLenders[i]] = newBorrowCaps[i];
            emit NewBorrowCap(fixedLenders[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Claim all the EXA accrued by holder in all markets
     * @param holder The address to claim EXA for
     */
    function claimExaAll(address holder) external {
        claimExa(holder, marketsAddresses);
    }

    /**
     * @dev Hook function to be called before someone supplies money to the smart pool
     *      This function basically checks if the address of the fixed Lender market is
     *      valid and makes sure to accrue EXA tokens to the market and the user.
     * @param fixedLenderAddress address of the fixed lender that will receive money in
     *                           it's smart pool
     * @param supplier address of the user that will supply money to the smart pool
     */
    function beforeSupplySP(address fixedLenderAddress, address supplier)
        external
        override
    {
        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        rewardsState.updateExaSPSupplyIndex(block.number, fixedLenderAddress);
        rewardsState.distributeSPSupplierExa(fixedLenderAddress, supplier);
    }

    /**
     * @dev Hook function to be called before someone withdraws money from the smart pool
     *      This function basically checks if the address of the fixed Lender market is
     *      valid and makes sure to accrue EXA tokens to the market and the user.
     * @param fixedLenderAddress address of the fixed lender that will receive money in
     *                           it's smart pool
     * @param supplier address of the user that will withdraw money from the smart pool
     */
    function beforeWithdrawSP(address fixedLenderAddress, address supplier)
        external
        override
    {
        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        rewardsState.updateExaSPSupplyIndex(block.number, fixedLenderAddress);
        rewardsState.distributeSPSupplierExa(fixedLenderAddress, supplier);
    }

    /**
     * @dev Hook function to be called before someone supplies money to a market/maturity.
     *      This function verifies if market is valid, maturity is valid, and accrues rewards accordingly.
     * @param fixedLenderAddress address of the fixedLender that will deposit money in a maturity
     * @param supplier address of the user that will supply money to a certain maturity (it can be later on
     *                 used as collater with _enterMarkets_ functions)
     * @param maturityDate timestamp for the maturity date that the user wants to supply money. It should
     *                     be in a VALID state (meaning that is not in the distant future, nor matured)
     */
    function beforeDepositMP(
        address fixedLenderAddress,
        address supplier,
        uint256 maturityDate
    ) external override {
        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        _requirePoolState(maturityDate, TSUtils.State.VALID);

        rewardsState.updateExaMPSupplyIndex(block.number, fixedLenderAddress);
        rewardsState.distributeMPSupplierExa(fixedLenderAddress, supplier);
    }

    /**
     * @dev Hook function to be called before someone borrows money to a market/maturity.
     *      This function verifies if market is valid, maturity is valid, checks if the user has enough collateral
     *      and accrues rewards accordingly.
     * @param fixedLenderAddress address of the fixedLender that will lend money in a maturity
     * @param borrower address of the user that will borrow money from a maturity date
     * @param borrowAmount amount that will be lent out to the borrower (expressed with same precision as underlying)
     * @param maturityDate timestamp for the maturity date that the user wants to borrow money. It should
     *                     be in a VALID state (meaning that is not in the distant future, nor matured)
     */
    function beforeBorrowMP(
        address fixedLenderAddress,
        address borrower,
        uint256 borrowAmount,
        uint256 maturityDate
    ) external override {
        if (book.borrowPaused[fixedLenderAddress]) {
            revert GenericError(ErrorCode.BORROW_PAUSED);
        }

        _requirePoolState(maturityDate, TSUtils.State.VALID);

        book.validateBorrow(
            fixedLenderAddress,
            borrower,
            borrowAmount,
            maturityDate
        );

        (, uint256 shortfall) = book.accountLiquidity(
            oracle,
            borrower,
            maturityDate,
            fixedLenderAddress,
            0,
            borrowAmount
        );

        if (shortfall > 0) {
            revert GenericError(ErrorCode.INSUFFICIENT_LIQUIDITY);
        }

        rewardsState.updateExaMPBorrowIndex(block.number, fixedLenderAddress);
        rewardsState.distributeMPBorrowerExa(fixedLenderAddress, borrower);
    }

    /**
     * @dev Hook function to be called before someone wants to receive its money back from a market/maturity.
     *      This function verifies if market is valid, maturity is MATURED, checks if the user has no outstanding
     *      debts and accrues rewards accordingly. This function is called from fixedLender contracts.
     * @param fixedLenderAddress address of the fixedLender that will lend money in a maturity
     * @param redeemer address of the user that wants to withdraw it's money
     * @param redeemAmount amount that the user wants to withdraw from the maturity
     * @param maturityDate timestamp for the maturity date that the user wants to get it's money from. It should
     *                     be in a MATURED state (meaning that the date is VALID + MATURED)
     */
    function beforeWithdrawMP(
        address fixedLenderAddress,
        address redeemer,
        uint256 redeemAmount,
        uint256 maturityDate
    ) external override {
        _beforeWithdrawMP(
            fixedLenderAddress,
            redeemer,
            redeemAmount,
            maturityDate
        );

        rewardsState.updateExaMPSupplyIndex(block.number, fixedLenderAddress);
        rewardsState.distributeMPSupplierExa(fixedLenderAddress, redeemer);
    }

    /**
     * @dev Hook function to be called before someone wants to repay its debt in a market/maturity.
     *      This function verifies if market is valid, maturity is MATURED and accrues rewards accordingly.
     *      This function is called from fixedLender contracts.
     * @param fixedLenderAddress address of the fixedLender that will collect money in a maturity
     * @param borrower address of the user that wants to repay its debt
     */
    function beforeRepayMP(address fixedLenderAddress, address borrower)
        external
        override
    {
        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        rewardsState.updateExaMPBorrowIndex(block.number, fixedLenderAddress);
        rewardsState.distributeMPBorrowerExa(fixedLenderAddress, borrower);
    }

    /**
     * @dev Function to allow/reject liquidation of assets. This function can be called
     *      externally, but only will have effect when called from a fixedLender.
     * @param fixedLenderCollateral market where the assets will be liquidated (should be msg.sender on FixedLender.sol)
     * @param fixedLenderBorrowed market from where the debt is pending
     * @param liquidator address that is liquidating the assets
     * @param borrower address which the assets are being liquidated
     * @param repayAmount amount to be repaid from the debt (outstanding debt * close factor should be bigger than this value)
     * @param maturityDate maturity where the position has a shortfall in liquidity
     */
    function liquidateAllowed(
        address fixedLenderBorrowed,
        address fixedLenderCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount,
        uint256 maturityDate
    ) external view override {
        if (repayAmount == 0) {
            revert GenericError(ErrorCode.REPAY_ZERO);
        }

        if (borrower == liquidator) {
            revert GenericError(ErrorCode.LIQUIDATOR_NOT_BORROWER);
        }

        // if markets are listed, they have the same auditor
        if (
            !book.markets[fixedLenderBorrowed].isListed ||
            !book.markets[fixedLenderCollateral].isListed
        ) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (, uint256 shortfall) = book.accountLiquidity(
            oracle,
            borrower,
            maturityDate,
            address(0),
            0,
            0
        );

        if (shortfall == 0) {
            revert GenericError(ErrorCode.UNSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        (, uint256 borrowBalance) = IFixedLender(fixedLenderBorrowed)
            .getAccountSnapshot(borrower, maturityDate);
        uint256 maxClose = closeFactor.mul_(borrowBalance);
        if (repayAmount > maxClose) {
            revert GenericError(ErrorCode.TOO_MUCH_REPAY);
        }
    }

    /**
     * @dev Function to allow/reject seizing of assets. This function can be called
     *      externally, but only will have effect when called from a fixedLender.
     * @param fixedLenderCollateral market where the assets will be seized (should be msg.sender on FixedLender.sol)
     * @param fixedLenderBorrowed market from where the debt will be paid
     * @param liquidator address to validate where the seized assets will be received
     * @param borrower address to validate where the assets will be removed
     */
    function seizeAllowed(
        address fixedLenderCollateral,
        address fixedLenderBorrowed,
        address liquidator,
        address borrower
    ) external view override {
        if (borrower == liquidator) {
            revert GenericError(ErrorCode.LIQUIDATOR_NOT_BORROWER);
        }

        // If markets are listed, they have also the same Auditor
        if (
            !book.markets[fixedLenderCollateral].isListed ||
            !book.markets[fixedLenderBorrowed].isListed
        ) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }
    }

    /**
     * @dev Given a fixedLender address, it returns the corresponding market data
     * @param fixedLenderAddress Address of the contract where we are getting the data
     */
    function getMarketData(address fixedLenderAddress)
        external
        view
        returns (
            string memory,
            string memory,
            bool,
            uint256,
            uint8
        )
    {
        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }
        MarketsLib.Market storage marketData = book.markets[fixedLenderAddress];
        return (
            marketData.symbol,
            marketData.name,
            marketData.isListed,
            marketData.collateralFactor,
            marketData.decimals
        );
    }

    /**
     * @dev Function to get account's liquidity for a certain maturity pool
     * @param account wallet to retrieve liquidity for a certain maturity date
     * @param maturityDate timestamp to calculate maturity's pool
     */
    function getAccountLiquidity(address account, uint256 maturityDate)
        external
        view
        override
        returns (uint256, uint256)
    {
        return
            book.accountLiquidity(
                oracle,
                account,
                maturityDate,
                address(0),
                0,
                0
            );
    }

    /**
     * @dev Function to calculate the amount of assets to be seized
     *      - when a position is undercollaterized it should be repaid and this functions calculates the
     *        amount of collateral to be seized
     * @param fixedLenderCollateral market where the assets will be liquidated (should be msg.sender on FixedLender.sol)
     * @param fixedLenderBorrowed market from where the debt is pending
     * @param actualRepayAmount repay amount in the borrowed asset
     */
    function liquidateCalculateSeizeAmount(
        address fixedLenderBorrowed,
        address fixedLenderCollateral,
        uint256 actualRepayAmount
    ) external view override returns (uint256) {
        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowed = oracle.getAssetPrice(
            IFixedLender(fixedLenderBorrowed).underlyingTokenName()
        );
        uint256 priceCollateral = oracle.getAssetPrice(
            IFixedLender(fixedLenderCollateral).underlyingTokenName()
        );

        uint256 amountInUSD = DecimalMath.getTokenAmountInUSD(
            actualRepayAmount,
            priceBorrowed,
            book.markets[fixedLenderBorrowed].decimals
        );
        // 10**18: usd amount decimals
        uint256 seizeTokens = DecimalMath.getTokenAmountFromUsd(
            amountInUSD,
            priceCollateral,
            book.markets[fixedLenderCollateral].decimals
        );

        return seizeTokens.mul_(liquidationIncentive);
    }

    /**
     * @dev Function to verify that a maturityDate is VALID, MATURED, NOT_READY or INVALID.
     *      If expected state doesn't match the calculated one, it reverts with a custom error "UnmatchedPoolState".
     * @param maturityDate timestamp of the maturity date to be verified
     * @param requiredState state required by the caller to be verified (see TSUtils.State() for description)
     */
    function requirePoolState(uint256 maturityDate, TSUtils.State requiredState)
        external
        view
        override
    {
        return _requirePoolState(maturityDate, requiredState);
    }

    /**
     * @dev Function to retrieve valid future pools
     */
    function getFuturePools()
        external
        view
        override
        returns (uint256[] memory)
    {
        return TSUtils.futurePools(block.timestamp, maxFuturePools);
    }

    /**
     * @dev Function to retrieve all markets
     */
    function getMarketAddresses()
        external
        view
        override
        returns (address[] memory)
    {
        return marketsAddresses;
    }

    /**
     * @notice Claim all the EXA accrued by holder in the specified markets
     * @param holder The address to claim EXA for
     * @param fixedLenders The list of markets to claim EXA in
     */
    function claimExa(address holder, address[] memory fixedLenders) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        rewardsState.claimExa(
            block.number,
            book.markets,
            holders,
            fixedLenders,
            true,
            true,
            true
        );
    }

    /**
     * @dev Internal Function to verify that a maturityDate is VALID, MATURED, NOT_READY or INVALID.
     *      If expected state doesn't match the calculated one, it reverts with a custom error "UnmatchedPoolState".
     * @param maturityDate timestamp of the maturity date to be verified
     * @param requiredState state required by the caller to be verified (see TSUtils.State() for description)
     */
    function _requirePoolState(
        uint256 maturityDate,
        TSUtils.State requiredState
    ) internal view {
        TSUtils.State poolState = TSUtils.getPoolState(
            block.timestamp,
            maturityDate,
            maxFuturePools
        );
        if (poolState != requiredState) {
            revert UnmatchedPoolState(poolState, requiredState);
        }
    }

    /**
     * @dev Internal function to be called before someone wants to receive its money back from a market/maturity.
     *      This function verifies if market is valid, maturity is MATURED, checks if the user has no outstanding
     *      debts. This function is called indirectly from fixedLender contracts(redeem) and directly from this
     *      when the user wants to exit a market.
     * @param fixedLenderAddress address of the fixedLender that will lend money in a maturity
     * @param redeemer address of the user that wants to withdraw it's money
     * @param redeemAmount amount that the user wants to withdraw from the maturity
     * @param maturityDate timestamp for the maturity date that the user wants to get it's money from. It should
     *                     be in a MATURED state (meaning that the date is VALID + MATURED)
     */
    function _beforeWithdrawMP(
        address fixedLenderAddress,
        address redeemer,
        uint256 redeemAmount,
        uint256 maturityDate
    ) internal view {
        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        _requirePoolState(maturityDate, TSUtils.State.MATURED);

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (
            !book.markets[fixedLenderAddress].accountMembership[redeemer][
                maturityDate
            ]
        ) {
            return;
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (, uint256 shortfall) = book.accountLiquidity(
            oracle,
            redeemer,
            maturityDate,
            fixedLenderAddress,
            redeemAmount,
            0
        );
        if (shortfall > 0) {
            revert GenericError(ErrorCode.INSUFFICIENT_LIQUIDITY);
        }
    }
}
