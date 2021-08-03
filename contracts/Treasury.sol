// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/ITreasury.sol";
import "./utils/Orchestrated.sol";
import "./utils/Maker.sol";
import "./utils/CompoundLib.sol";
import "./interfaces/ICToken.sol";
import "hardhat/console.sol";

contract Treasury is ITreasury, Orchestrated() {

    IWeth public override weth;
    DaiAbstract public override dai;

    using Maker for Maker.Adapters;
    using CompoundLib for CompoundLib.Adapters;

    Maker.Adapters private makerAdapter;
    CompoundLib.Adapters private compoundAdapter;

    function getAdapter() external override view returns (Maker.Adapters memory) {
        return makerAdapter;
    }

    constructor (
        address vat_,
        address weth_,
        address wethJoin_,
        address dai_,
        address daiJoin_,
        address ctoken_
    ) {
        weth = IWeth(weth_);
        dai = DaiAbstract(dai_);

        makerAdapter.wethJoin = GemJoinAbstract(wethJoin_);
        makerAdapter.daiJoin = DaiJoinAbstract(daiJoin_);
        makerAdapter.vat = VatAbstract(vat_);

        makerAdapter.vat.hope(wethJoin_); // add gemJoin contract to talk for me to Vault engine
        makerAdapter.vat.hope(daiJoin_);  // add daiJoin contract to talk for me to Vault engine

        compoundAdapter.ctoken = ICToken(ctoken_);

        weth.approve(address(makerAdapter.wethJoin), type(uint256).max);  // weth we trust
        dai.approve(address(makerAdapter.daiJoin), type(uint256).max);    // dai we trust
        dai.approve(address(compoundAdapter.ctoken), type(uint256).max); // ctoken we trust
    }

    /**
     * @dev Takes WETH from a wallet
     * 
     * @param from Wallet to get the WETH from.
     * @param amountWeth WETH quantity to receive.
     */
    function pushWeth(address from, uint256 amountWeth)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        require(weth.transferFrom(from, address(this), amountWeth));
        makerAdapter.addWeth(amountWeth);
        // TODO: Rebalance everythings based on "amountWeth"
    }

    /**
     * @dev Sends WETH to a wallet
     * 
     * @param to Wallet to send the WETH to.
     * @param amountWeth WETH quantity to send.
     */
    function pullWeth(address to, uint256 amountWeth)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        // TODO: Rebalance everythings based on "amountWeth"
        makerAdapter.retrieveWeth(amountWeth, to);
    }

    /**
     * @dev Takes dai from user and pays as much system debt as possible, saving the rest.
     *      User needs to have approved Treasury to take the Dai.
     * 
     * @param from Wallet to get the Dai from.
     * @param amountDai Dai quantity to receive.
     */
    function pushDai(address from, uint256 amountDai)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        require(dai.transferFrom(from, address(this), amountDai));
        // TODO: Rebalance everythings based on "amountDai"
    }

    /**
     * @dev Returns dai using savings as much as possible, and borrowing the rest.
     *      This function can only be called by other EXA contracts, not users directly.
     * 
     * @param to Wallet to send Dai to.
     * @param amountDai Dai quantity to send.
     */
    function pullDai(address to, uint256 amountDai)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        // TODO: Rebalance everythings based on "amountDai"
        dai.transfer(to, amountDai);
    }

    /**
     * @dev Returns the Treasury debt towards MakerDAO, in Dai.
     */
    function debt() public view override returns(uint256) {
        return makerAdapter.debtFor(address(this));
    }

    /**
     * @dev Returns the amount of savings in this contract, converted to Dai.
     * 
     * This function is NOT view since compound can modify state when using "rate"
     * which is needed to know how much money we have in DAI (DAI = CToken * Rate)
     */
    function savings() public override returns(uint256) {
        return compoundAdapter.balanceOf(address(this));
    }

}
