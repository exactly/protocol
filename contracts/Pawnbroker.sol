// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "dss-interfaces/src/dss/VatAbstract.sol";
import "./interfaces/IPawnbroker.sol";
import "./interfaces/ITreasury.sol";
import "./utils/Orchestrated.sol";
import "./utils/Maker.sol";

contract Pawnbroker is Ownable, IPawnbroker, Orchestrated(), MakerAdaptersProvider {

    enum ValueChange { Increased, Decreased }
    event CollateralChanged(address indexed user, ValueChange changeType, uint256 amount);

    uint256 public constant DUST = 50e15; // 0.05 ETH ~= 100 USD (2021)

    mapping(address => uint256) public collaterals;
    mapping(address => uint256) public debt;

    ITreasury public treasury;

    Maker.Adapters private madapter;

    function makerAdapters() external view override returns (Maker.Adapters memory) {
        Maker.Adapters memory ma = madapter;
        return ma;
    }

    constructor (address treasury_) {
        treasury = ITreasury(treasury_);
        madapter = MakerAdaptersProvider(treasury_).makerAdapters();
    }

    function addCollateral(address from, address to, uint256 amount) public override {
        uint256 collateral = collaterals[to];
        collaterals[to] = collateral += amount;
        require(hasMoreThanMinimum(to), "Pawnbroker: total collateral below minimum");
        treasury.pushWeth(from, amount);
        emit CollateralChanged(to, ValueChange.Increased, amount);
    }

    function withdrawCollateral(address from, address to, uint256 amount) public override {
        uint256 collateral = collaterals[from];
        collaterals[from] = collateral -= (amount);
        require(isCollateralized(from), "Pawnbroker: Too much debt");
        require(hasMoreThanMinimum(from) || hasZeroCollateral(from), "Pawnbroker: total collateral left under minimum");
        treasury.pullWeth(to, amount);
        emit CollateralChanged(to, ValueChange.Decreased, amount);
    }

    function isCollateralized(address user) public view override returns (bool) {
        return powerOf(user) >= totalDebtDai(user);
    }

    function hasMoreThanMinimum(address user) public view returns (bool) {
        uint256 collateral = collaterals[user];
        return DUST < collateral;
    }

    function hasZeroCollateral(address user) public view returns (bool) {
        uint256 collateral = collaterals[user];
        return collateral == 0;
    }

    function powerOf(address user) public view returns (uint256) {
        uint256 collateral = collaterals[user];
        return Maker.ethPriceInDai(collateral);
    }

    function totalDebtDai(address user) public view returns (uint256) {
        // TODO: Implement this. This is only to remove warnings from compiler
        return debt[user];
    }
}
