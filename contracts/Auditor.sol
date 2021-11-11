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
import "hardhat/console.sol";

contract Auditor is IAuditor, AccessControl {
    using DecimalMath for uint256;
    using SafeCast for uint256;
    using ExaLib for ExaLib.RewardsState;
    using MarketsLib for MarketsLib.Book;

    event MarketListed(address fixedLender);
    event MarketEntered(address fixedLender, address account, uint256 maturityDate);
    event MarketExited(address fixedLender, address account, uint256 maturityDate);
    event ActionPaused(address fixedLender, string action, bool paused);
    event OracleChanged(address newOracle);
    event NewBorrowCap(address indexed fixedLender, uint256 newBorrowCap);
    event ExaSpeedUpdated(address fixedLenderAddress, uint256 newSpeed);
    event DistributedSupplierExa(
        address indexed fixedLender,
        address indexed supplier,
        uint256 supplierDelta,
        uint256 exaSupplyIndex
    );
    event DistributedBorrowerExa(
        address indexed fixedLender,
        address indexed borrower,
        uint256 borrowerDelta,
        uint256 exaSupplyIndex
    );
    event DistributedSmartPoolExa(
        address indexed fixedLender,
        address indexed supplier,
        uint smartSupplierDelta,
        uint smartPoolIndex
    );

    // Protocol Management
    MarketsLib.Book private book;

    uint256 public closeFactor = 5e17;
    uint8 public maxFuturePools = 12; // if every 14 days, then 6 months
    address[] public marketsAddresses;

    // Rewards Management
    ExaLib.RewardsState public rewardsState;

    IOracle public oracle;

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
    function exitMarket(address fixedLenderAddress, uint256 maturityDate) external {
        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        IFixedLender fixedLender = IFixedLender(fixedLenderAddress);

        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        (uint256 amountHeld, uint256 borrowBalance) = fixedLender.getAccountSnapshot(
            msg.sender,
            maturityDate
        );

        /* Fail if the sender has a borrow balance */
        if (borrowBalance != 0) {
            revert GenericError(ErrorCode.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        _redeemAllowed(fixedLenderAddress, msg.sender, amountHeld, maturityDate);

        book.exitMarket(fixedLenderAddress, msg.sender, maturityDate);
    }

    /**
     * @dev Function to get account's liquidity for a certain maturity pool
     * @param account wallet to retrieve liquidity for a certain maturity date
     * @param maturityDate timestamp to calculate maturity's pool
     */
    function getAccountLiquidity(address account, uint256 maturityDate)
        public
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

    function beforeSupplySmartPool(
        address fixedLenderAddress,
        address supplier
    ) override external {
        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        rewardsState.updateExaSmartPoolIndex(block.number, fixedLenderAddress);
        rewardsState.distributeSmartPoolExa(fixedLenderAddress, supplier);
    }

    function beforeWithdrawSmartPool(
        address fixedLenderAddress,
        address supplier
    ) override external {
        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        rewardsState.updateExaSmartPoolIndex(block.number, fixedLenderAddress);
        rewardsState.distributeSmartPoolExa(fixedLenderAddress, supplier);
    }

    function supplyAllowed(
        address fixedLenderAddress,
        address supplier,
        uint256 supplyAmount,
        uint256 maturityDate
    ) external override {
        supplyAmount;

        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        _requirePoolState(maturityDate, TSUtils.State.VALID);

        rewardsState.updateExaSupplyIndex(block.number, fixedLenderAddress);
        rewardsState.distributeSupplierExa(fixedLenderAddress, supplier);
    }

    function requirePoolState(uint256 maturityDate, TSUtils.State requiredState)
        external
        view
        override
    {
        return _requirePoolState(maturityDate, requiredState);
    }

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

    function borrowAllowed(
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
            oracle,
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

        rewardsState.updateExaBorrowIndex(block.number, fixedLenderAddress);
        rewardsState.distributeBorrowerExa(fixedLenderAddress, borrower);
    }

    function redeemAllowed(
        address fixedLenderAddress,
        address redeemer,
        uint256 redeemTokens,
        uint256 maturityDate
    ) external override {
        _redeemAllowed(fixedLenderAddress, redeemer, redeemTokens, maturityDate);

        rewardsState.updateExaSupplyIndex(block.number, fixedLenderAddress);
        rewardsState.distributeSupplierExa(fixedLenderAddress, redeemer);
    }

    function _redeemAllowed(
        address fixedLenderAddress,
        address redeemer,
        uint256 redeemTokens,
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
            redeemTokens,
            0
        );
        if (shortfall > 0) {
            revert GenericError(ErrorCode.INSUFFICIENT_LIQUIDITY);
        }
    }

    function repayAllowed(
        address fixedLenderAddress,
        address borrower,
        uint256 maturityDate
    ) external override {
        if (!book.markets[fixedLenderAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        _requirePoolState(maturityDate, TSUtils.State.MATURED);

        rewardsState.updateExaBorrowIndex(block.number, fixedLenderAddress);
        rewardsState.distributeBorrowerExa(fixedLenderAddress, borrower);
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

        return seizeTokens;
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
        (, uint256 shortfall) = book.accountLiquidity(oracle, borrower, maturityDate, address(0), 0, 0);
        TSUtils.State currentState = TSUtils.getPoolState(block.timestamp, maturityDate, maxFuturePools);
        // positions without shortfall are liquidateable if they are overdue
        if (shortfall == 0 && currentState != TSUtils.State.MATURED) {
            revert GenericError(ErrorCode.UNSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        (, uint256 borrowBalance) = IFixedLender(fixedLenderBorrowed).getAccountSnapshot(
            borrower,
            maturityDate
        );
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
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
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
     * @dev Function to pause/unpause borrowing on a certain market
     * @param fixedLender address to pause
     * @param paused true/false
     */
    function pauseBorrow(address fixedLender, bool paused)
        public
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
     * @dev Function to set Oracle's to be used
     * @param _priceOracleAddress address of the new oracle
     */
    function setOracle(address _priceOracleAddress) public onlyRole(DEFAULT_ADMIN_ROLE) {
        oracle = IOracle(_priceOracleAddress);
        emit OracleChanged(_priceOracleAddress);
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
            rewardsState.setExaSpeed(block.number, fixedLenderAddress, exaSpeed) ==
            true
        ) {
            emit ExaSpeedUpdated(fixedLenderAddress, exaSpeed);
        }
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
     * @notice Claim all the EXA accrued by holder in all markets
     * @param holder The address to claim EXA for
     */
    function claimExaAll(address holder) external {
        claimExa(holder, marketsAddresses);
    }

    /**
     * @notice Claim all the EXA accrued by holder in the specified markets
     * @param holder The address to claim EXA for
     * @param fixedLenders The list of markets to claim EXA in
     */
    function claimExa(address holder, address[] memory fixedLenders) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        rewardsState.claimExa(block.number, book.markets, holders, fixedLenders, true, true, true);
    }
}
