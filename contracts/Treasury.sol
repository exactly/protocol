// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/ITreasury.sol";
import "./utils/Orchestrated.sol";
import "./utils/Maker.sol";
import "./utils/Yearn.sol";
import "hardhat/console.sol";

contract Treasury is ITreasury, Orchestrated() {

    IWeth public override weth;
    DaiAbstract public override dai;

    using Maker for Maker.Adapters;
    using Yearn for Yearn.Adapters;

    Maker.Adapters private makerAdapter;
    Yearn.Adapters private yearnAdapter;

    function getAdapter() external override view returns (Maker.Adapters memory) {
        return makerAdapter;
    }

    constructor (
        address vat_,
        address weth_,
        address wethJoin_,
        address dai_,
        address daiJoin_,
        address ydai_
    ) {
        weth = IWeth(weth_);
        dai = DaiAbstract(dai_);

        makerAdapter.wethJoin = GemJoinAbstract(wethJoin_);
        makerAdapter.daiJoin = DaiJoinAbstract(daiJoin_);
        makerAdapter.vat = VatAbstract(vat_);

        makerAdapter.vat.hope(wethJoin_); // add gemJoin contract to talk for me to Vault engine
        makerAdapter.vat.hope(daiJoin_);  // add daiJoin contract to talk for me to Vault engine

        yearnAdapter.ydai = IyDAI(ydai_);

        weth.approve(address(makerAdapter.wethJoin), type(uint256).max); // weth we trust
        dai.approve(address(makerAdapter.daiJoin), type(uint256).max);   // dai we trust
        dai.approve(address(yearnAdapter.ydai), type(uint256).max);      // ydai we trust
    }

    function pushWeth(address from, uint256 amountWeth)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        require(weth.transferFrom(from, address(this), amountWeth));
        makerAdapter.addWeth(amountWeth);
    }

    function pullWeth(address to, uint256 amountWeth)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        makerAdapter.retrieveWeth(amountWeth, to);
    }

    /// @dev Takes dai from user and pays as much system debt as possible, saving the rest.
    /// User needs to have approved Treasury to take the Dai.
    /// This function can only be called by other EXA contracts, not users directly.
    /// @param from Wallet to take Dai from.
    /// @param amountDai Dai quantity to take.
    function pushDai(address from, uint256 amountDai)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        require(dai.transferFrom(from, address(this), amountDai));

        uint256 toRepay = Math.min(debt(), amountDai);
        if (toRepay > 0) {
            makerAdapter.returnDai(toRepay);
        }

        uint256 toSave = amountDai - toRepay;
        if (toSave > 0) {
            yearnAdapter.deposit(amountDai);
        }
    }

    /// @dev Returns dai using savings as much as possible, and borrowing the rest.
    /// This function can only be called by other EXA contracts, not users directly.
    /// @param to Wallet to send Dai to.
    /// @param amountDai Dai quantity to send.
    function pullDai(address to, uint256 amountDai)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        uint256 toBorrow = amountDai - toRelease; // toRelease can't be greater than dai
        if (toBorrow > 0) {
            makerAdapter.retrieveDai(toBorrow, address(this));
        }
        dai.transfer(to, amountDai);              // Give dai to user - Dai doesn't have a return value for `transfer`
    }

    /// @dev Returns the Treasury debt towards MakerDAO, in Dai.
    function debt() public view override returns(uint256) {
        return makerAdapter.debtFor(address(this));
    }

    /// @dev Returns the amount of savings in this contract, converted to Dai.
    function savings() public view override returns(uint256) {
        return yearnAdapter.savingsInDai(address(this));
    }

}
