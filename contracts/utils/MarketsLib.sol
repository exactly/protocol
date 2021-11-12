// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IExafin.sol";
import "../interfaces/IOracle.sol";
import "./TSUtils.sol";
import "../utils/Errors.sol";
import "../utils/DecimalMath.sol";

library MarketsLib {

    using DecimalMath for uint256;

    event MarketEntered(address exafin, address account);
    event MarketExited(address exafin, address account);

    // Struct to avoid stack too deep
    struct AccountLiquidity {
        uint256 balance;
        uint256 borrowBalance;
        uint256 collateralFactor;
        uint256 oraclePrice;
        uint256 sumCollateral;
        uint256 sumDebt;
    }

    // Book-keeping
    struct Book {
        mapping(address => MarketsLib.Market) markets;
        mapping(address => bool) borrowPaused;
        mapping(address => uint256) borrowCaps;
        mapping(address => mapping(uint256 => IExafin[])) accountAssets;
    }

    // Struct for Exafin's markets
    struct Market {
        string symbol;
        string name;
        bool isListed;
        uint256 collateralFactor;
        uint8 decimals;
        mapping(address => mapping(uint256 => bool)) accountMembership;
    }

    /**
     * @dev Allows a user to start participating in a market
     * @param book book in which the addMarket function will be applied to
     * @param exafinAddress address used to retrieve the market data
     * @param who address of the user that it will start participating in a market/maturity
     * @param maturityDate poolID in which it will start participating
     */
    function addToMarket(Book storage book, address exafinAddress, address who, uint256 maturityDate) public {
        MarketsLib.Market storage marketToJoin = book.markets[exafinAddress];
        addToMaturity(marketToJoin, who, maturityDate);
        book.accountAssets[who][maturityDate].push(IExafin(exafinAddress));
        emit MarketEntered(exafinAddress, who);
    }

    /**
     * @dev Allows wallet to enter certain markets (exafinDAI, exafinETH, etc)
     *      By performing this action, the wallet's money could be used as collateral
     * @param market Market in which the user will be a added to a certain maturity
     * @param borrower wallet that wants to enter a market
     * @param maturityDate poolID in which the wallet will be added to
     */
    function addToMaturity(Market storage market, address borrower, uint256 maturityDate) internal {
        if(!TSUtils.isPoolID(maturityDate)) { 
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        if (!market.isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        if (market.accountMembership[borrower][maturityDate] == true) {
            return;
        }

        market.accountMembership[borrower][maturityDate] = true;
    }

    /**
     * @dev Allows wallet to exit certain markets (exafinDAI, exafinETH, etc)
     *      By performing this action, the wallet's money stops being used as collateral
     * @param book book in which the addMarket function will be applied to
     * @param exafinAddress market address used to retrieve the market data
     * @param who wallet that wants to exit a market/maturity
     * @param maturityDate poolID in which the wallet will stop using as collateral
     */
    function exitMarket(Book storage book, address exafinAddress, address who, uint256 maturityDate) external {
        MarketsLib.Market storage marketToExit = book.markets[exafinAddress];

        if (marketToExit.accountMembership[who][maturityDate] == false) {
            return;
        }

        delete marketToExit.accountMembership[who][maturityDate];

        // load into memory for faster iteration
        IExafin[] memory userAssetList = book.accountAssets[who][maturityDate];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == IExafin(exafinAddress)) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        IExafin[] storage storedList = book.accountAssets[who][maturityDate];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(exafinAddress, who);
    }

    /**
     * @dev Function to get account's liquidity for a certain market/maturity pool
     * @param book account book that it will be used to calculate liquidity
     * @param oracle oracle used to perform all liquidity calculations
     * @param account wallet which the liquidity will be calculated
     * @param maturityDate timestamp to calculate maturity's pool
     * @param exafinToSimulate exafin in which we want to simulate redeem/borrow ops (see next two args)
     * @param redeemAmount amount to simulate redeem
     * @param borrowAmount amount to simulate borrow
     */
    function accountLiquidity(
        Book storage book,
        IOracle oracle,
        address account,
        uint256 maturityDate,
        address exafinToSimulate,
        uint256 redeemAmount,
        uint256 borrowAmount
    )
        external 
        view
        returns (
            uint256,
            uint256
        )
    {

        AccountLiquidity memory vars; // Holds all our calculation results

        // For each asset the account is in
        IExafin[] memory assets = book.accountAssets[account][maturityDate];
        for (uint256 i = 0; i < assets.length; i++) {
            IExafin asset = assets[i];
            MarketsLib.Market storage market = book.markets[address(asset)];

            // Read the balances
            (vars.balance, vars.borrowBalance) = asset.getAccountSnapshot(
                account,
                maturityDate
            );
            vars.collateralFactor = book.markets[address(asset)].collateralFactor;

            // Get the normalized price of the asset (18 decimals)
            vars.oraclePrice = oracle.getAssetPrice(asset.tokenName());

            // We sum all the collateral prices
            vars.sumCollateral += DecimalMath.getTokenAmountInUSD(vars.balance, vars.oraclePrice, market.decimals).mul_(vars.collateralFactor);

            // We sum all the debt
            vars.sumDebt += DecimalMath.getTokenAmountInUSD(vars.borrowBalance, vars.oraclePrice, market.decimals);

            // Simulate the effects of borrowing from/lending to a pool
            if (asset == IExafin(exafinToSimulate)) {
                // Calculate the effects of borrowing exafins
                if (borrowAmount != 0) {
                    vars.sumDebt += DecimalMath.getTokenAmountInUSD(borrowAmount, vars.oraclePrice, market.decimals);
                }

                // Calculate the effects of redeeming exafins
                // (having less collateral is the same as having more debt for this calculation)
                if (redeemAmount != 0) {
                    vars.sumDebt += DecimalMath.getTokenAmountInUSD(redeemAmount, vars.oraclePrice, market.decimals).mul_(vars.collateralFactor);
                }
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumDebt) {
            return (vars.sumCollateral - vars.sumDebt, 0);
        } else {
            return (0, vars.sumDebt - vars.sumCollateral);
        }
    }

    /**
     * @dev Function to validate if a borrow should be allowed based on the what the book says.
            if the user is not participating in a market, and the caller is an exafin, the function
            will subscribe the wallet to the market membership
     * @param book account book that it will be used to perform validation
     * @param oracle oracle used to perform all liquidity calculations
     * @param exafinAddress address of the market that the borrow will be validated. If this equals msg.sender
              then the wallet will be autosubscribed to the market membership,
     * @param borrower address which will be borrowing money from this market
     * @param borrowAmount amount to be valide the borrow action with
     * @param maturityDate of the market that the borrow will be validated.
     */
    function validateBorrow(
        Book storage book,
        IOracle oracle,
        address exafinAddress,
        address borrower,
        uint256 borrowAmount,
        uint256 maturityDate
    ) external {
        if (!book.markets[exafinAddress].isListed) {
            revert GenericError(ErrorCode.MARKET_NOT_LISTED);
        }

        if (!book.markets[exafinAddress].accountMembership[borrower][maturityDate]) {
            // only exafins may call borrowAllowed if borrower not in market
            if (msg.sender != exafinAddress) {
                revert GenericError(ErrorCode.NOT_AN_EXAFIN_SENDER);
            }

            // attempt to add borrower to the market // reverts if error
            addToMarket(book, exafinAddress, borrower, maturityDate);

            // it should be impossible to break the important invariant
            assert(book.markets[exafinAddress].accountMembership[borrower][maturityDate]);
        }

        // We check that the asset price is valid
        oracle.getAssetPrice(IExafin(exafinAddress).tokenName());

        uint256 borrowCap = book.borrowCaps[exafinAddress];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint256 totalBorrows = IExafin(exafinAddress).getTotalBorrows(
                maturityDate
            );
            uint256 nextTotalBorrows = totalBorrows + borrowAmount;
            if (nextTotalBorrows >= borrowCap) {
                revert GenericError(ErrorCode.MARKET_BORROW_CAP_REACHED);
            }
        }

    }

}
