// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./interfaces/IExafin.sol";
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

    bytes32 public constant TEAM_ROLE = keccak256("TEAM_ROLE");

    event MarketListed(address exafin);
    event MarketEntered(address exafin, address account, uint256 maturityDate);
    event MarketExited(address exafin, address account, uint256 maturityDate);
    event ActionPaused(address exafin, string action, bool paused);
    event OracleChanged(address newOracle);
    event NewBorrowCap(address indexed exafin, uint256 newBorrowCap);
    event ExaSpeedUpdated(address exafinAddress, uint256 newSpeed);
    event DistributedSupplierExa(
        address indexed exafin,
        address indexed supplier,
        uint supplierDelta,
        uint exaSupplyIndex
    );
    event DistributedBorrowerExa(
        address indexed exafin,
        address indexed borrower,
        uint borrowerDelta,
        uint exaSupplyIndex
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
        _setupRole(TEAM_ROLE, msg.sender);
    }

    /**
     * @dev Allows wallet to enter certain markets (exafinDAI, exafinETH, etc)
     *      By performing this action, the wallet's money could be used as collateral
     * @param exafins contracts addresses to enable for `msg.sender` for a certain maturity
     * @param maturityDate poolID in which the exafins will be enabled
     */
    function enterMarkets(address[] calldata exafins, uint256 maturityDate)
        external
    {
        _requirePoolState(maturityDate, TSUtils.State.VALID);
        uint256 len = exafins.length;
        for (uint256 i = 0; i < len; i++) {
            book.addToMarket(exafins[i], msg.sender, maturityDate);
        }
    }

    /**
     * @notice Removes exafin from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *      or be providing necessary collateral for an outstanding borrow.
     * @param exafinAddress The address of the asset to be removed
     * @param maturityDate The timestamp/poolID where the user wants to stop providing collateral
     */
    function exitMarket(address exafinAddress, uint256 maturityDate) external {

        if (!book.markets[exafinAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        IExafin exafin = IExafin(exafinAddress);

        if(!TSUtils.isPoolID(maturityDate)) { 
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        (uint256 amountHeld, uint256 borrowBalance) = exafin.getAccountSnapshot(msg.sender, maturityDate);

        /* Fail if the sender has a borrow balance */
        if (borrowBalance != 0) {
            revert GenericError(ErrorCode.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        _redeemAllowed(exafinAddress, msg.sender, amountHeld, maturityDate);
        console.log("estoy3");

        book.exitMarket(exafinAddress, msg.sender, maturityDate);
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
        returns (
            uint256,
            uint256
        )
    {
        return book.accountLiquidity(oracle, account, maturityDate, address(0), 0, 0);
    }



    function supplyAllowed(
        address exafinAddress,
        address supplier,
        uint256 supplyAmount,
        uint256 maturityDate
    ) override external {
        supplyAmount;

        if (!book.markets[exafinAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        _requirePoolState(maturityDate, TSUtils.State.VALID);

        rewardsState.updateExaSupplyIndex(block.number, exafinAddress);
        rewardsState.distributeSupplierExa(exafinAddress, supplier);
    }

    function requirePoolState(uint256 maturityDate, TSUtils.State requiredState) external override view {
        return _requirePoolState(maturityDate, requiredState);
    }

    function _requirePoolState(uint256 maturityDate, TSUtils.State requiredState) internal view {
        TSUtils.State poolState = TSUtils.getPoolState(block.timestamp, maturityDate, maxFuturePools);
        if(poolState != requiredState) {
            revert UnmatchedPoolState(poolState, requiredState);
        }
    }

    function borrowAllowed(
        address exafinAddress,
        address borrower,
        uint256 borrowAmount,
        uint256 maturityDate
    ) external override {

        if (book.borrowPaused[exafinAddress]) {
            revert GenericError(ErrorCode.BORROW_PAUSED);
        }

        _requirePoolState(maturityDate, TSUtils.State.VALID); 

        book.validateBorrow(oracle, exafinAddress, borrower, borrowAmount, maturityDate);

        (, uint256 shortfall) = book.accountLiquidity(
            oracle,
            borrower,
            maturityDate,
            exafinAddress,
            0,
            borrowAmount
        );

        if (shortfall > 0) {
            revert GenericError(ErrorCode.INSUFFICIENT_LIQUIDITY);
        }

        rewardsState.updateExaBorrowIndex(block.number, exafinAddress);
        rewardsState.distributeBorrowerExa(exafinAddress, borrower);
    }

    function redeemAllowed(
        address exafinAddress,
        address redeemer,
        uint256 redeemTokens,
        uint256 maturityDate
    ) override external {
        _redeemAllowed(exafinAddress, redeemer, redeemTokens, maturityDate);

        rewardsState.updateExaSupplyIndex(block.number, exafinAddress);
        rewardsState.distributeSupplierExa(exafinAddress, redeemer);
    }

    function _redeemAllowed(
        address exafinAddress,
        address redeemer,
        uint256 redeemTokens,
        uint256 maturityDate
    ) internal view {
        if (!book.markets[exafinAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        _requirePoolState(maturityDate, TSUtils.State.MATURED); 

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!book.markets[exafinAddress].accountMembership[redeemer][maturityDate]) {
            return;
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (, uint256 shortfall) = book.accountLiquidity(
            oracle,
            redeemer,
            maturityDate,
            exafinAddress,
            redeemTokens,
            0
        );
        if (shortfall > 0) {
            revert GenericError(ErrorCode.INSUFFICIENT_LIQUIDITY);
        }
    }

    function repayAllowed(
        address exafinAddress,
        address borrower,
        uint256 maturityDate
    ) override external {

        if (!book.markets[exafinAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        _requirePoolState(maturityDate, TSUtils.State.MATURED);

        rewardsState.updateExaBorrowIndex(block.number, exafinAddress);
        rewardsState.distributeBorrowerExa(exafinAddress, borrower);
    }

    /**
     * @dev Function to calculate the amount of assets to be seized
     *      - when a position is undercollaterized it should be repaid and this functions calculates the 
     *        amount of collateral to be seized
     * @param exafinCollateral market where the assets will be liquidated (should be msg.sender on Exafin.sol)
     * @param exafinBorrowed market from where the debt is pending
     * @param actualRepayAmount repay amount in the borrowed asset
     */
    function liquidateCalculateSeizeAmount(
        address exafinBorrowed,
        address exafinCollateral,
        uint256 actualRepayAmount
    ) override external view returns (uint256) {

        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowed = oracle.getAssetPrice(IExafin(exafinBorrowed).tokenName());
        uint256 priceCollateral = oracle.getAssetPrice(IExafin(exafinCollateral).tokenName());

        uint256 amountInUSD = DecimalMath.getTokenAmountInUSD(actualRepayAmount, priceBorrowed, book.markets[exafinBorrowed].decimals);
        // 10**18: usd amount decimals
        uint256 seizeTokens = DecimalMath.getTokenAmountFromUsd(amountInUSD, priceCollateral, book.markets[exafinCollateral].decimals);

        return seizeTokens;
    }

    /**
     * @dev Function to allow/reject liquidation of assets. This function can be called 
     *      externally, but only will have effect when called from an exafin. 
     * @param exafinCollateral market where the assets will be liquidated (should be msg.sender on Exafin.sol)
     * @param exafinBorrowed market from where the debt is pending
     * @param liquidator address that is liquidating the assets
     * @param borrower address which the assets are being liquidated
     * @param repayAmount amount to be repaid from the debt (outstanding debt * close factor should be bigger than this value)
     * @param maturityDate maturity where the position has a shortfall in liquidity
     */
    function liquidateAllowed(
        address exafinBorrowed,
        address exafinCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount,
        uint256 maturityDate
    ) override external view {

        if (repayAmount == 0) {
            revert GenericError(ErrorCode.REPAY_ZERO);
        }

        if (borrower == liquidator) {
            revert GenericError(ErrorCode.LIQUIDATOR_NOT_BORROWER);
        }

        // if markets are listed, they have the same auditor
        if (!book.markets[exafinBorrowed].isListed || !book.markets[exafinCollateral].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (, uint256 shortfall) = book.accountLiquidity(oracle, borrower, maturityDate, address(0), 0, 0);
        if (shortfall == 0) {
            revert GenericError(ErrorCode.UNSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        (,uint256 borrowBalance) = IExafin(exafinBorrowed).getAccountSnapshot(borrower, maturityDate);
        uint256 maxClose = closeFactor.mul_(borrowBalance);
        if (repayAmount > maxClose) {
            revert GenericError(ErrorCode.TOO_MUCH_REPAY);
        }
    }

    /**
     * @dev Function to allow/reject seizing of assets. This function can be called 
     *      externally, but only will have effect when called from an exafin. 
     * @param exafinCollateral market where the assets will be seized (should be msg.sender on Exafin.sol)
     * @param exafinBorrowed market from where the debt will be paid
     * @param liquidator address to validate where the seized assets will be received
     * @param borrower address to validate where the assets will be removed
     */
    function seizeAllowed(
        address exafinCollateral,
        address exafinBorrowed,
        address liquidator,
        address borrower
    ) override external view {

        if (borrower == liquidator) {
            revert GenericError(ErrorCode.LIQUIDATOR_NOT_BORROWER);
        }

        // If markets are listed, they have also the same Auditor
        if (!book.markets[exafinCollateral].isListed || !book.markets[exafinBorrowed].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }
    }

    /**
     * @dev Function to enable a certain Exafin market to be used as collateral
     * @param exafin address to add to the protocol
     * @param collateralFactor exafin's collateral factor for the underlying asset
     */
    function enableMarket(
        address exafin,
        uint256 collateralFactor,
        string memory symbol,
        string memory name,
        uint8 decimals
    ) public onlyRole(TEAM_ROLE) {
        MarketsLib.Market storage market = book.markets[exafin];

        if (market.isListed) {
            revert GenericError(ErrorCode.MARKET_ALREADY_LISTED);
        }

        if (IExafin(exafin).getAuditor() != this) {
            revert GenericError(ErrorCode.AUDITOR_MISMATCH);
        }

        market.isListed = true;
        market.collateralFactor = collateralFactor;
        market.symbol = symbol;
        market.name = name;
        market.decimals = decimals;

        marketsAddresses.push(exafin);

        emit MarketListed(exafin);
    }

    /**
     * @notice Set the given borrow caps for the given exafin markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @param exafins The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function setMarketBorrowCaps(
        address[] calldata exafins,
        uint256[] calldata newBorrowCaps
    ) external onlyRole(TEAM_ROLE) {
        uint256 numMarkets = exafins.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        if (numMarkets == 0 || numMarkets != numBorrowCaps) {
            revert GenericError(ErrorCode.INVALID_SET_BORROW_CAP);
        }

        for(uint256 i = 0; i < numMarkets; i++) {
            if (!book.markets[exafins[i]].isListed) {
                revert GenericError(ErrorCode.MARKET_NOT_LISTED);
            }

            book.borrowCaps[exafins[i]] = newBorrowCaps[i];
            emit NewBorrowCap(exafins[i], newBorrowCaps[i]);
        }
    }

    /**
     * @dev Function to pause/unpause borrowing on a certain market
     * @param exafin address to pause
     * @param paused true/false
     */
    function pauseBorrow(address exafin, bool paused)
        public
        onlyRole(TEAM_ROLE)
        returns (bool)
    {
        if (!book.markets[exafin].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        book.borrowPaused[address(exafin)] = paused;
        emit ActionPaused(exafin, "Borrow", paused);
        return paused;
    }

    /**
     * @dev Function to set Oracle's to be used
     * @param _priceOracleAddress address of the new oracle
     */
    function setOracle(address _priceOracleAddress) public onlyRole(TEAM_ROLE) {
        oracle = IOracle(_priceOracleAddress);
        emit OracleChanged(_priceOracleAddress);
    }

    /**
     * @notice Set EXA speed for a single market
     * @param exafinAddress The market whose EXA speed to update
     * @param exaSpeed New EXA speed for market
     */
    function setExaSpeed(address exafinAddress, uint256 exaSpeed) external onlyRole(TEAM_ROLE) {
        MarketsLib.Market storage market = book.markets[exafinAddress];
        if(market.isListed == false) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        if(rewardsState.setExaSpeed(block.number, exafinAddress, exaSpeed) == true) {
            emit ExaSpeedUpdated(exafinAddress, exaSpeed);
        }
    }

    /**
     * @dev Function to retrieve valid future pools
     */
    function getFuturePools() override external view returns (uint256[] memory) {
        return TSUtils.futurePools(block.timestamp, maxFuturePools);
    }

    /**
     * @dev Function to retrieve all markets
     */
    function getMarketAddresses() override external view returns (address[] memory) {
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
     * @param exafins The list of markets to claim EXA in
     */
    function claimExa(address holder, address[] memory exafins) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        rewardsState.claimExa(block.number, book.markets, holders, exafins, true, true);
    }

}
