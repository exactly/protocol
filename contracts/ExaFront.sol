// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IExafin.sol";
import "./interfaces/IExaFront.sol";
import "./interfaces/Oracle.sol";
import "./utils/TSUtils.sol";
import "./utils/DecimalMath.sol";
import "hardhat/console.sol";

contract ExaFront is Ownable, IExaFront {
    
    using TSUtils for uint256;
    using DecimalMath for uint256;

    event MarketEntered(IExafin exafin, address account);

    mapping(address => Market) public markets;
    mapping(address => IExafin[]) public accountAssets;
 
    struct Market {
        bool isListed;
        uint collateralFactor;
        mapping(address => bool) accountMembership;
    }

    struct AccountLiquidity {
        uint balance;
        uint borrowBalance;
        uint collateralFactor;
        uint oraclePrice;
        uint sumCollateral;
        uint sumDebt;
    }

    enum Error {
        MARKET_NOT_LISTED,
        NO_ERROR,
        SNAPSHOT_ERROR,
        PRICE_ERROR
    }

    Oracle private oracle;

    constructor (address _priceOracleAddress) {
        oracle = Oracle(_priceOracleAddress);
    }

    function setOracle(address _priceOracleAddress) public onlyOwner { 
        oracle = Oracle(_priceOracleAddress);
    }

    /**
        @dev Allows wallet to enter certain markets (exafinDAI, exafinETH, etc)
             By performing this action, the wallet's money could be used as collateral
        @param exafins contracts addresses to enable for `msg.sender`
     */
    function enterMarkets(address[] calldata exafins) external returns (uint256[] memory) {
        uint len = exafins.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            IExafin exafin = IExafin(exafins[i]);

            results[i] = uint(addToMarketInternal(exafin, msg.sender));
        }

        return results;
    }

    /**
        @dev (internal)
            Allows wallet to enter certain markets (exafinDAI, exafinETH, etc)
            By performing this action, the wallet's money could be used as collateral
        @param exafin contracts addresses to enable
        @param borrower wallet that wants to enter a market
     */
    function addToMarketInternal(IExafin exafin, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(exafin)];

        if (!marketToJoin.isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            return Error.NO_ERROR;
        }

        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(exafin);

        emit MarketEntered(exafin, borrower);

        return Error.NO_ERROR;
    }

    /**
        @dev Function to get account's liquidity for a certain maturity pool
        @param account wallet to retrieve liquidity for a certain maturity date
        @param maturityDate timestamp to calculate maturity's pool
     */
    function getAccountLiquidity(address account, uint256 maturityDate) override public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, maturityDate, address(0), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
        @dev Function to get account's liquidity for a certain maturity pool (allows estimations TODO)
        @param account wallet to retrieve liquidity for a certain maturity date
        @param maturityDate timestamp to calculate maturity's pool
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        uint256 maturityDate,
        address exafinModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidity memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        IExafin[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            IExafin asset = assets[i];

            // Read the balances // TODO calculate using NFT
            (oErr, vars.balance, vars.borrowBalance) = asset.getAccountSnapshot(account, maturityDate);

            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }

            vars.collateralFactor = markets[address(asset)].collateralFactor;

            // Get the normalized price of the asset (6 decimals)
            vars.oraclePrice = oracle.price(asset.tokenName());
            if (vars.oraclePrice == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }

            // We sum all the collateral prices
            vars.sumCollateral = vars.balance.mul_(vars.collateralFactor).mul_(vars.oraclePrice, 1e6) + vars.sumCollateral;

            // We sum all the debt
            vars.sumDebt = vars.borrowBalance.mul_(vars.oraclePrice, 1e6) + vars.sumDebt;

            // Calculate effects of borrowing from/lending to a pool
            // TODO
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumDebt) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumDebt, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumDebt - vars.sumCollateral);
        }
    }

    /**
        @dev Function to enable a certain Exafin market to be used as collateral
        @param exafin address to add to the protocol
        @param collateralFactor exafin's collateral factor for the underlying asset
     */
    function enableMarket(address exafin, uint collateralFactor) public onlyOwner {
        Market storage market = markets[exafin];
        market.isListed = true;
        market.collateralFactor = collateralFactor;
    }
}
