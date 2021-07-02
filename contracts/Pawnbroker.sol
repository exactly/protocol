// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "dss-interfaces/src/dss/VatAbstract.sol";
import "./interfaces/IPawnbroker.sol";
import "./interfaces/ITreasury.sol";
import "./utils/Orchestrated.sol";

contract Pawnbroker is Ownable, IPawnbroker, Orchestrated() {
    using SafeMath for uint256;

    enum ValueChange { Increased, Decreased }
    event CollateralChanged(address indexed user, ValueChange changeType, uint256 amount);

    bytes32 public constant WETH = "ETH-A";
    uint256 public constant MIN_COLLATERAL = 50e15; // 0.05 ETH ~= 100 USD (2021)
    uint256 public constant UNIT = 1e27; // RAY (27 decimals)

    mapping(address => uint256) public collaterals;
    mapping(address => uint256) public debt;

    ITreasury public treasury;
    VatAbstract public vat;

    constructor (address treasury_) {
        treasury = ITreasury(treasury_);
        vat = treasury.vat();
    }

    function addCollateral(address from, address to, uint256 amount) public override {
        uint256 collateral = collaterals[to];
        collaterals[to] = collateral.add(amount);
        require(hasMoreThanMinimum(to), "Pawnbroker: total collateral below minimum");
        treasury.pushWeth(from, amount);
        emit CollateralChanged(to, ValueChange.Increased, amount);
    }

    function withdrawCollateral(address from, address to, uint256 amount) public override {
        uint256 collateral = collaterals[from];
        collaterals[from] = collateral.sub(amount);

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
        return MIN_COLLATERAL < collateral;
    }

    function hasZeroCollateral(address user) public view returns (bool) {
        uint256 collateral = collaterals[user];
        return collateral == 0;
    }

    function powerOf(address user) public view returns (uint256) {
        /*
        https://github.com/makerdao/developerguides/blob/master/vault/monitoring-collateral-types-and-vaults/monitoring-collateral-types-and-vaults.md
        struct Ilk {
            uint256 Art;   // Total Normalised Debt     [wad]
            uint256 rate;  // Accumulated Rates         [ray]
            uint256 spot;  // Price with Safety Margin  [ray]
            uint256 line;  // Debt Ceiling              [rad]
            uint256 dust;  // Urn Debt Floor            [rad]
        }
        */
        (,, uint256 spot,,) = vat.ilks(WETH);
        uint256 collateral = collaterals[user];
        // dai = (collateral (ie: 1ETH) * price (ie: 2200 DAI/ETH)) / 1e27(RAD->RAY) 
        return collateral.mul(spot).div(UNIT);
    }

    function totalDebtDai(address user) public view returns (uint256) {
        // TODO: Implement this. This is only to remove warnings from compiler
        return debt[user];
    }
}
