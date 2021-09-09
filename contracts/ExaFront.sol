// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IExafin.sol";
import "./interfaces/IExaFront.sol";
import "./interfaces/Oracle.sol";
import "./utils/TSUtils.sol";
import "./utils/DecimalMath.sol";
import "./utils/Errors.sol";
import "hardhat/console.sol";

contract ExaFront is Ownable, IExaFront {
    using TSUtils for uint256;
    using DecimalMath for uint256;

    event MarketEntered(IExafin exafin, address account);
    event ActionPaused(address exafin, string action, bool paused);

    mapping(address => Market) public markets;
    mapping(address => BaseMarket) public listedMarkets;
    mapping(address => bool) public borrowPaused;
    mapping(address => uint256) public borrowCaps;
    mapping(address => IExafin[]) public accountAssets;

    uint256 private marketCount = 0;
    address[] marketsAddress;

    struct BaseMarket {
        string symbol;
        string name;
        bool isListed;
        uint256 collateralFactor;
        bool exists;
    }

    struct Market {
        BaseMarket baseMarket;
        mapping(address => bool) accountMembership;
    }

    struct AccountLiquidity {
        uint256 balance;
        uint256 borrowBalance;
        uint256 collateralFactor;
        uint256 oraclePrice;
        uint256 sumCollateral;
        uint256 sumDebt;
    }

    Oracle private oracle;

    constructor(address _priceOracleAddress) {
        oracle = Oracle(_priceOracleAddress);
    }

    /**
        @dev Allows wallet to enter certain markets (exafinDAI, exafinETH, etc)
             By performing this action, the wallet's money could be used as collateral
        @param exafins contracts addresses to enable for `msg.sender`
     */
    function enterMarkets(address[] calldata exafins)
        external
        returns (uint256[] memory)
    {
        uint256 len = exafins.length;

        uint256[] memory results = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            IExafin exafin = IExafin(exafins[i]);

            results[i] = uint256(addToMarketInternal(exafin, msg.sender));
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
    function addToMarketInternal(IExafin exafin, address borrower)
        internal
        returns (Error)
    {
        Market storage marketToJoin = markets[address(exafin)];

        if (!marketToJoin.baseMarket.isListed) {
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
    function getAccountLiquidity(address account, uint256 maturityDate)
        public
        view
        override
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        (
            Error err,
            uint256 liquidity,
            uint256 shortfall
        ) = getHypotheticalAccountLiquidityInternal(
                account,
                maturityDate,
                address(0),
                0,
                0
            );

        return (uint256(err), liquidity, shortfall);
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
        uint256 redeemTokens,
        uint256 borrowAmount
    )
        internal
        view
        returns (
            Error,
            uint256,
            uint256
        )
    {
        AccountLiquidity memory vars; // Holds all our calculation results
        uint256 oErr;

        // For each asset the account is in
        IExafin[] memory assets = accountAssets[account];
        for (uint256 i = 0; i < assets.length; i++) {
            IExafin asset = assets[i];

            // Read the balances // TODO calculate using NFT
            (oErr, vars.balance, vars.borrowBalance) = asset.getAccountSnapshot(
                account,
                maturityDate
            );

            if (oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }

            vars.collateralFactor = markets[address(asset)]
                .baseMarket
                .collateralFactor;

            // Get the normalized price of the asset (6 decimals)
            vars.oraclePrice = oracle.price(asset.tokenName());
            if (vars.oraclePrice == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }

            // We sum all the collateral prices
            vars.sumCollateral =
                vars.balance.mul_(vars.collateralFactor).mul_(
                    vars.oraclePrice,
                    1e6
                ) +
                vars.sumCollateral;

            // We sum all the debt
            vars.sumDebt =
                vars.borrowBalance.mul_(vars.oraclePrice, 1e6) +
                vars.sumDebt;

            // Calculate effects of borrowing from/lending to a pool
            if (asset == IExafin(exafinModify)) {
                if (borrowAmount != 0) {
                    vars.sumDebt =
                        borrowAmount.mul_(vars.oraclePrice, 1e6) +
                        vars.sumDebt;
                }
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumDebt) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumDebt, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumDebt - vars.sumCollateral);
        }
    }

    function borrowAllowed(
        address exafinAddress,
        address borrower,
        uint256 borrowAmount,
        uint256 maturityDate
    ) external override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowPaused[exafinAddress], "borrow is paused");

        if (!markets[exafinAddress].baseMarket.isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (!markets[exafinAddress].accountMembership[borrower]) {
            // only cTokens may call borrowAllowed if borrower not in market
            require(msg.sender == exafinAddress, "sender must be cToken");

            // attempt to add borrower to the market
            Error errAdd = addToMarketInternal(IExafin(msg.sender), borrower);
            if (errAdd != Error.NO_ERROR) {
                return uint256(errAdd);
            }

            // it should be impossible to break the important invariant
            assert(markets[exafinAddress].accountMembership[borrower]);
        }

        if (oracle.price(IExafin(exafinAddress).tokenName()) == 0) {
            return uint256(Error.PRICE_ERROR);
        }

        uint256 borrowCap = borrowCaps[exafinAddress];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint256 totalBorrows = IExafin(exafinAddress).getTotalBorrows(
                maturityDate
            );
            uint256 nextTotalBorrows = totalBorrows + borrowAmount;
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (
            Error err,
            ,
            uint256 shortfall
        ) = getHypotheticalAccountLiquidityInternal(
                borrower,
                maturityDate,
                exafinAddress,
                0,
                borrowAmount
            );
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
        @dev Function to enable a certain Exafin market to be used as collateral
        @param exafin address to add to the protocol
        @param collateralFactor exafin's collateral factor for the underlying asset
     */
    function enableMarket(
        address exafin,
        uint256 collateralFactor,
        string memory symbol,
        string memory name
    ) public onlyOwner {
        Market storage market = markets[exafin];
        market.baseMarket.isListed = true;
        market.baseMarket.exists = true;
        market.baseMarket.collateralFactor = collateralFactor;
        market.baseMarket.symbol = symbol;
        market.baseMarket.name = name;

        listedMarkets[exafin] = market.baseMarket;

        marketCount += 1;
        marketsAddress.push(exafin);
    }

    /**
        @dev List all markets, listed or not
     */
    function getMarkets()
        public
        view
        returns (
            address[] memory,
            string[] memory,
            bool[] memory,
            uint256[] memory,
            string[] memory
        )
    {
        bool[] memory marketsListed = new bool[](marketCount);
        string[] memory marketsSymbol = new string[](marketCount);
        string[] memory marketsName = new string[](marketCount);
        uint256[] memory marketsCollateralFactor = new uint256[](marketCount);

        for (uint256 i = 0; i < marketCount; i++) {
            Market storage market = markets[marketsAddress[i]];
            marketsListed[i] = market.baseMarket.isListed;
            marketsSymbol[i] = market.baseMarket.symbol;
            marketsName[i] = market.baseMarket.name;
            marketsCollateralFactor[i] = market.baseMarket.collateralFactor;
        }

        return (
            marketsAddress,
            marketsSymbol,
            marketsListed,
            marketsCollateralFactor,
            marketsName
        );
    }

    /**
        @dev Get market data filtered by address
        @param contractAddress address to get market data
     */
    function getMarketByAddress(address contractAddress)
        public
        view
        returns (
            address,
            string memory,
            bool,
            uint256,
            string memory
        )
    {
        Market storage market = markets[contractAddress];

        return (
            contractAddress,
            market.baseMarket.symbol,
            market.baseMarket.isListed,
            market.baseMarket.collateralFactor,
            market.baseMarket.name
        );
    }

    /**
        @dev Add market to listedMarkets and change boolean to true
        @param exafin address to add to the protocol
     */
    function listMarket(address exafin) public {
        require(markets[exafin].baseMarket.exists, "Address is not a market");
        markets[exafin].baseMarket.isListed = true;
        listedMarkets[exafin] = markets[exafin].baseMarket;
    }

    /**
        @dev Delete market to listedMarkets and change boolean to false
        @param exafin address to add to the protocol
     */
    function unlistMarket(address exafin) public {
        require(markets[exafin].baseMarket.exists, "Address is not a market");
        markets[exafin].baseMarket.isListed = false;
        delete listedMarkets[exafin];
    }

    /**
        @dev Function to pause/unpause borrowing on a certain market
        @param exafin address to pause
        @param paused true/false
     */
    function pauseBorrow(address exafin, bool paused)
        public
        onlyOwner
        returns (bool)
    {
        require(markets[exafin].baseMarket.isListed, "not listed");

        borrowPaused[address(exafin)] = paused;
        emit ActionPaused(exafin, "Borrow", paused);
        return paused;
    }

    function setOracle(address _priceOracleAddress) public onlyOwner {
        oracle = Oracle(_priceOracleAddress);
    }
}
