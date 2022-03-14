// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import { IFixedLender, NotFixedLender } from "../interfaces/IFixedLender.sol";
import { PoolLib } from "./PoolLib.sol";
import "../interfaces/IOracle.sol";

library MarketsLib {
    using FixedPointMathLib for uint256;

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
        mapping(address => uint256) borrowCaps;
        mapping(address => IFixedLender[]) accountAssets;
    }

    // Struct for FixedLender's markets
    struct Market {
        string symbol;
        string name;
        bool isListed;
        uint256 collateralFactor;
        uint8 decimals;
        mapping(address => bool) accountMembership;
    }

    event MarketEntered(address indexed fixedLender, address account);
    event MarketExited(address indexed fixedLender, address account);

    /**
     * @dev Allows wallet to exit certain markets (fixedLenderDAI, fixedLenderETH, etc)
     *      By performing this action, the wallet's money stops being used as collateral
     * @param book book in which the addMarket function will be applied to
     * @param fixedLenderAddress market address used to retrieve the market data
     * @param who wallet that wants to exit a market/maturity
     */
    function exitMarket(
        Book storage book,
        address fixedLenderAddress,
        address who
    ) external {
        MarketsLib.Market storage marketToExit = book.markets[
            fixedLenderAddress
        ];

        if (marketToExit.accountMembership[who] == false) {
            return;
        }

        delete marketToExit.accountMembership[who];

        // load into memory for faster iteration
        IFixedLender[] memory userAssetList = book.accountAssets[who];
        uint256 len = userAssetList.length;
        uint256 assetIndex = len;
        for (uint256 i = 0; i < len; i++) {
            if (userAssetList[i] == IFixedLender(fixedLenderAddress)) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        IFixedLender[] storage storedList = book.accountAssets[who];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(fixedLenderAddress, who);
    }

    /**
     * @dev Function to validate if a borrow should be allowed based on the what the book says.
            if the user is not participating in a market, and the caller is a fixedLender, the function
            will subscribe the wallet to the market membership
     * @param book account book that it will be used to perform validation
     * @param fixedLenderAddress address of the market that the borrow will be validated. If this equals msg.sender
              then the wallet will be autosubscribed to the market membership,
     * @param borrower address which will be borrowing money from this market
     */
    function validateBorrow(
        Book storage book,
        address fixedLenderAddress,
        address borrower
    ) external {
        if (!book.markets[fixedLenderAddress].accountMembership[borrower]) {
            // only fixedLenders may call borrowAllowed if borrower not in market
            if (msg.sender != fixedLenderAddress) revert NotFixedLender();

            // attempt to add borrower to the market // reverts if error
            addToMarket(book, fixedLenderAddress, borrower);

            // it should be impossible to break the important invariant
            // TODO: is this tested?
            assert(
                book.markets[fixedLenderAddress].accountMembership[borrower]
            );
        }

        uint256 borrowCap = book.borrowCaps[fixedLenderAddress];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint256 totalBorrows = IFixedLender(fixedLenderAddress)
                .totalMpBorrows();
            if (totalBorrows >= borrowCap) revert BorrowCapReached();
        }
    }

    /**
     * @dev Function to get account's liquidity for a certain market/maturity pool
     * @param book account book that it will be used to calculate liquidity
     * @param oracle oracle used to perform all liquidity calculations
     * @param account wallet which the liquidity will be calculated
     * @param fixedLenderToSimulate fixedLender in which we want to simulate withdraw/borrow ops (see next two args)
     * @param withdrawAmount amount to simulate withdraw
     * @param borrowAmount amount to simulate borrow
     */
    function accountLiquidity(
        Book storage book,
        IOracle oracle,
        address account,
        address fixedLenderToSimulate,
        uint256 withdrawAmount,
        uint256 borrowAmount
    ) external view returns (uint256, uint256) {
        AccountLiquidity memory vars; // Holds all our calculation results

        // For each asset the account is in
        IFixedLender[] memory assets = book.accountAssets[account];
        for (uint256 i = 0; i < assets.length; i++) {
            IFixedLender asset = assets[i];
            MarketsLib.Market storage market = book.markets[address(asset)];

            // Read the balances
            (vars.balance, vars.borrowBalance) = asset.getAccountSnapshot(
                account,
                PoolLib.MATURITY_ALL
            );

            vars.collateralFactor = book
                .markets[address(asset)]
                .collateralFactor;

            // Get the normalized price of the asset (18 decimals)
            vars.oraclePrice = oracle.getAssetPrice(
                asset.underlyingTokenSymbol()
            );

            // We sum all the collateral prices
            vars.sumCollateral += vars
                .balance
                .fmul(vars.oraclePrice, 10**market.decimals)
                .fmul(vars.collateralFactor, 1e18);

            // We sum all the debt
            vars.sumDebt += vars.borrowBalance.fmul(
                vars.oraclePrice,
                10**market.decimals
            );

            // Simulate the effects of borrowing from/lending to a pool
            if (asset == IFixedLender(fixedLenderToSimulate)) {
                // Calculate the effects of borrowing fixedLenders
                if (borrowAmount != 0) {
                    vars.sumDebt += borrowAmount.fmul(
                        vars.oraclePrice,
                        10**market.decimals
                    );
                }

                // Calculate the effects of redeeming fixedLenders
                // (having less collateral is the same as having more debt for this calculation)
                if (withdrawAmount != 0) {
                    vars.sumDebt += withdrawAmount
                        .fmul(vars.oraclePrice, 10**market.decimals)
                        .fmul(vars.collateralFactor, 1e18);
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
     * @dev Allows a user to start participating in a market
     * @param book book in which the addMarket function will be applied to
     * @param fixedLenderAddress address used to retrieve the market data
     * @param who address of the user that it will start participating in a market/maturity
     */
    function addToMarket(
        Book storage book,
        address fixedLenderAddress,
        address who
    ) public {
        MarketsLib.Market storage marketToJoin = book.markets[
            fixedLenderAddress
        ];

        if (marketToJoin.accountMembership[who] == true) {
            return;
        }

        marketToJoin.accountMembership[who] = true;

        book.accountAssets[who].push(IFixedLender(fixedLenderAddress));
        emit MarketEntered(fixedLenderAddress, who);
    }
}

error BorrowCapReached();
