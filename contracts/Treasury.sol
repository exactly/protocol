// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/ITreasury.sol";
import "./utils/Orchestrated.sol";
import "./utils/Maker.sol";
import "hardhat/console.sol";

contract Treasury is ITreasury, Orchestrated(), MakerAdaptersHolder {

    IWeth public override weth;
    DaiAbstract public override dai;

    Maker.Adapters private madapter;

    function makerAdapters() external view override returns (Maker.Adapters memory) {
        Maker.Adapters memory ma = madapter;
        return ma;
    }

    constructor (
        address vat_,
        address weth_,
        address wethJoin_,
        address dai_,
        address daiJoin_
    ) {
        weth = IWeth(weth_);
        dai = DaiAbstract(dai_);

        GemJoinAbstract wethJoin = GemJoinAbstract(wethJoin_); // adapter of the valt for ERC20
        DaiJoinAbstract daiJoin = DaiJoinAbstract(daiJoin_);
        VatAbstract vat = VatAbstract(vat_);
        vat.hope(wethJoin_); // add gemJoin contract to talk for me to Vault engine
        vat.hope(daiJoin_); // add gemJoin contract to talk for me to Vault engine

        madapter.wethJoin = wethJoin;
        madapter.daiJoin = daiJoin;
        madapter.vat = vat;

        weth.approve(address(wethJoin), type(uint256).max); // weth we trust
        dai.approve(address(daiJoin), type(uint256).max); // dai we trust
    }

    function pushWeth(address from, uint256 amountWeth)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        require(weth.transferFrom(from, address(this), amountWeth));

        Maker.addWeth(amountWeth);
    }

    function pullWeth(address to, uint256 amountWeth)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        Maker.retrieveWeth(amountWeth, to);
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
        require(dai.transferFrom(from, address(this), amountDai));  // Take dai from user to Treasury

        uint256 toRepay = Math.min(debt(), amountDai);
        if (toRepay > 0) {
            Maker.addDai(toRepay);
        }

        uint256 toSave = amountDai - toRepay;          // toRepay can't be greater than dai
        if (toSave > 0) {
            // Save to Yearn
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
        uint256 toRelease = Math.min(savings(), amountDai);
        if (toRelease > 0) {
            // TODO: Go get to the savings account (Yearn or something)
        }

        uint256 toBorrow = amountDai - toRelease; // toRelease can't be greater than dai
        if (toBorrow > 0) {
            Maker.retrieveDai(toBorrow, address(this));
        }
        dai.transfer(to, amountDai);               // Give dai to user - Dai doesn't have a return value for `transfer`
    }

    /// @dev Returns the Treasury debt towards MakerDAO, in Dai.
    function debt() public view override returns(uint256) {
        return Maker.debtFor(address(this));
    }

    /// @dev Returns the amount of savings in this contract, converted to Dai.
    function savings() public view override returns(uint256) {
        return 0;
    }

}
