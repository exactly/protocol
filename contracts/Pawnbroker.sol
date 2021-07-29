// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "dss-interfaces/src/dss/VatAbstract.sol";
import "./interfaces/IPawnbroker.sol";
import "./interfaces/ITreasury.sol";
import "./utils/Orchestrated.sol";
import "./utils/Maker.sol";

contract Pawnbroker is Ownable, IPawnbroker, Orchestrated() {

    enum ValueChange { Increased, Decreased }
    event CollateralChanged(address indexed user, ValueChange changeType, uint256 amount);

    uint256 public constant DUST = 50e15; // 0.05 ETH ~= 100 USD (2021)

    mapping(address => uint256) public collaterals;
    mapping(address => uint256) public debt;

    ITreasury public treasury;

    using Maker for Maker.Adapters;
    Maker.Adapters private makerAdapter;

    constructor (address treasury_) {
        treasury = ITreasury(treasury_);
        makerAdapter = treasury.getAdapter();
    }

    function addCollateral(address from, address to, uint256 amount) public override {

        uint256 collateral = collaterals[to];

        require(DUST < collateral || collateral == 0, "Pawnbroker: total collateral below minimum");

        collaterals[to] = collateral + amount;

        treasury.pushWeth(from, amount);

        emit CollateralChanged(to, ValueChange.Increased, amount);
    }

    function withdrawCollateral(address from, address to, uint256 amount) public override {

        uint256 collateral = collaterals[from];
        collaterals[from] = collateral - amount;

        require(makerAdapter.ethPriceInDai(collateral) >= totalDebtDai(from), "Pawnbroker: Too much debt");
        require(DUST < collateral || collateral == 0, "Pawnbroker: total collateral left under minimum");

        treasury.pullWeth(to, amount);

        emit CollateralChanged(to, ValueChange.Decreased, amount);
    }

    function powerOf(address user) public view returns (uint256) {
        uint256 collateral = collaterals[user];
        return makerAdapter.ethPriceInDai(collateral);
    }

    function totalDebtDai(address user) public view returns (uint256) {
        return debt[user];
    }
}
