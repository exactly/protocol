// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "./interfaces/IExafin.sol";
import "./interfaces/IAuditor.sol";
import "./interfaces/Oracle.sol";
import "./utils/TSUtils.sol";
import "./utils/DecimalMath.sol";
import "./utils/Errors.sol";
import "hardhat/console.sol";

contract Auditor is Ownable, IAuditor, AccessControl {
    bytes32 public constant TEAM_ROLE = keccak256("TEAM_ROLE");

    using DecimalMath for uint256;

    event MarketEntered(IExafin exafin, address account);
    event ActionPaused(address exafin, string action, bool paused);

    mapping(address => Market) public markets;
    mapping(address => BaseMarket) public listedMarkets;
    mapping(address => bool) public borrowPaused;
    mapping(address => uint256) public borrowCaps;
    mapping(address => IExafin[]) public accountAssets;

    uint256 private marketCount = 0;
    address[] public marketsAddress;

    uint256 public closeFactor = 5e17;

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
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(TEAM_ROLE, msg.sender);
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

            results[i] = uint256(_addToMarket(exafin, msg.sender));
        }

        return results;
    }

    /**
        @dev
            Allows wallet to enter certain markets (exafinDAI, exafinETH, etc)
            By performing this action, the wallet's money could be used as collateral
        @param exafin contracts addresses to enable
        @param borrower wallet that wants to enter a market
     */
    function _addToMarket(IExafin exafin, address borrower)
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
            uint256
        )
    {
        return _accountLiquidity(account, maturityDate, address(0), 0, 0);
    }

    /**
        @dev Function to get account's liquidity for a certain maturity pool
        @param account wallet to retrieve liquidity for a certain maturity date
        @param maturityDate timestamp to calculate maturity's pool
     */
    function _accountLiquidity(
        address account,
        uint256 maturityDate,
        address exafinToSimulate,
        uint256 redeemAmount,
        uint256 borrowAmount
    )
        internal
        view
        returns (
            uint256,
            uint256
        )
    {

        AccountLiquidity memory vars; // Holds all our calculation results

        // For each asset the account is in
        IExafin[] memory assets = accountAssets[account];
        for (uint256 i = 0; i < assets.length; i++) {
            IExafin asset = assets[i];

            // Read the balances
            (vars.balance, vars.borrowBalance) = asset.getAccountSnapshot(
                account,
                maturityDate
            );

            vars.collateralFactor = markets[address(asset)]
                .baseMarket
                .collateralFactor;

            // Get the normalized price of the asset (6 decimals)
            vars.oraclePrice = oracle.price(asset.tokenName());
            require(vars.oraclePrice != 0, "Price Oracle error");

            // We sum all the collateral prices
            vars.sumCollateral += vars.balance.mul_(vars.collateralFactor).mul_(
                vars.oraclePrice,
                1e6
            );

            // We sum all the debt
            vars.sumDebt += vars.borrowBalance.mul_(vars.oraclePrice, 1e6);

            // Simulate the effects of borrowing from/lending to a pool
            if (asset == IExafin(exafinToSimulate)) {
                // Calculate the effects of borrowing exafins
                if (borrowAmount != 0) {
                    vars.sumDebt += borrowAmount.mul_(vars.oraclePrice, 1e6);
                }

                // Calculate the effects of redeeming exafins
                // (having less collateral is the same as having more debt for this calculation)
                if (redeemAmount != 0) {
                    vars.sumDebt += redeemAmount
                        .mul_(vars.collateralFactor)
                        .mul_(vars.oraclePrice, 1e6);
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

    function supplyAllowed(
        address exafinAddress,
        address supplier,
        uint256 supplyAmount,
        uint256 maturityDate
    ) external view override returns (uint256) {
        supplier;
        supplyAmount;

        if (!markets[exafinAddress].baseMarket.isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        require(TSUtils.isPoolID(maturityDate) == true, "Not a pool ID");
        require(block.timestamp < maturityDate, "Pool Matured");

        return uint256(Error.NO_ERROR);
    }

    function borrowAllowed(
        address exafinAddress,
        address borrower,
        uint256 borrowAmount,
        uint256 maturityDate
    ) external override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowPaused[exafinAddress], "borrow is paused");

        require(TSUtils.isPoolID(maturityDate) == true, "Not a pool ID");
        require(block.timestamp < maturityDate, "Pool Matured");

        if (!markets[exafinAddress].baseMarket.isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (!markets[exafinAddress].accountMembership[borrower]) {
            // only exafins may call borrowAllowed if borrower not in market
            require(msg.sender == exafinAddress, "sender must be exafin");

            // attempt to add borrower to the market
            Error errAdd = _addToMarket(IExafin(msg.sender), borrower);
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

        (, uint256 shortfall) = _accountLiquidity(
            borrower,
            maturityDate,
            exafinAddress,
            0,
            borrowAmount
        );
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint256(Error.NO_ERROR);
    }

    function redeemAllowed(
        address exafinAddress,
        address redeemer,
        uint256 redeemTokens,
        uint256 maturityDate
    ) external view override returns (uint256) {
        if (!markets[exafinAddress].baseMarket.isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        require(TSUtils.isPoolID(maturityDate) == true, "Not a pool ID");
        require(block.timestamp > maturityDate, "Pool Not Mature");

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[exafinAddress].accountMembership[redeemer]) {
            return uint256(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (, uint256 shortfall) = _accountLiquidity(
            redeemer,
            maturityDate,
            exafinAddress,
            redeemTokens,
            0
        );
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint256(Error.NO_ERROR);
    }

    function repayAllowed(
        address exafinAddress,
        address borrower,
        uint256 repayAmount,
        uint256 maturityDate
    ) override external view returns (uint) {
        borrower;
        repayAmount;

        if (!markets[exafinAddress].baseMarket.isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        require(TSUtils.isPoolID(maturityDate) == true, "Not a pool ID");
        require(block.timestamp > maturityDate, "Pool Not Mature");

        return uint(Error.NO_ERROR);
    }

    function liquidateCalculateSeizeAmount(
        address exafinBorrowed,
        address exafinCollateral,
        uint256 actualRepayAmount
    ) override external view returns (uint, uint) {

        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowed = oracle.price(IExafin(exafinBorrowed).tokenName());
        uint256 priceCollateral = oracle.price(IExafin(exafinCollateral).tokenName());
        if (priceBorrowed == 0 || priceCollateral == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        uint256 amountInUSD = actualRepayAmount.mul_(priceBorrowed, 1e6);
        uint256 seizeTokens = priceCollateral.div_(amountInUSD);

        return (uint(Error.NO_ERROR), seizeTokens);
    }


    function liquidateAllowed(
        address exafinBorrowed,
        address exafinCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount,
        uint256 maturityDate
    ) override external view returns (uint) {

        require(repayAmount > 0, "Repay amount shouldn't be zero");
        require(borrower != liquidator, "Liquidator shouldn't be borrower");

        if (!markets[exafinBorrowed].baseMarket.isListed || !markets[exafinCollateral].baseMarket.isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (IExafin(exafinBorrowed).getAuditor() != IExafin(exafinCollateral).getAuditor()) {
            return uint(Error.AUDITOR_MISMATCH);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (, uint256 shortfall) =  _accountLiquidity(borrower, maturityDate, address(0), 0, 0);
        require(shortfall > 0, "Unsufficient Shortfall");

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        (uint borrowBalance,) = IExafin(exafinBorrowed).getAccountSnapshot(borrower, maturityDate);
        uint maxClose = closeFactor.mul_(borrowBalance);
        if (repayAmount > maxClose) {
            return uint(Error.TOO_MUCH_REPAY);
        }

        return uint(Error.NO_ERROR);
    }

    function seizeAllowed(
        address exafinCollateral,
        address exafinBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) override external view returns (uint) {

        // Shh - currently unused
        seizeTokens;

        require(borrower != liquidator, "Liquidator shouldn't be borrower");

        if (!markets[exafinCollateral].baseMarket.isListed || !markets[exafinBorrowed].baseMarket.isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (IExafin(exafinCollateral).getAuditor() != IExafin(exafinBorrowed).getAuditor()) {
            return uint(Error.AUDITOR_MISMATCH);
        }

        return uint(Error.NO_ERROR);
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
    ) public onlyRole(TEAM_ROLE) {
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
        @dev Add market to listedMarkets and change boolean to true
        @param exafin address to add to the protocol
     */
    function listMarket(address exafin) public onlyRole(TEAM_ROLE) {
        require(markets[exafin].baseMarket.exists, "Address is not a market");
        markets[exafin].baseMarket.isListed = true;
        listedMarkets[exafin] = markets[exafin].baseMarket;
    }

    /**
        @dev Delete market to listedMarkets and change boolean to false
        @param exafin address to add to the protocol
     */
    function unlistMarket(address exafin) public onlyRole(TEAM_ROLE) {
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
        onlyRole(TEAM_ROLE)
        returns (bool)
    {
        require(markets[exafin].baseMarket.isListed, "not listed");

        borrowPaused[address(exafin)] = paused;
        emit ActionPaused(exafin, "Borrow", paused);
        return paused;
    }

    /**
        @dev Function to set Oracle's to be used
        @param _priceOracleAddress address of the new oracle
     */
    function setOracle(address _priceOracleAddress) public onlyRole(TEAM_ROLE) {
        oracle = Oracle(_priceOracleAddress);
    }
}
