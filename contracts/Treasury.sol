// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/ITreasury.sol";
import "./utils/Orchestrated.sol";
import "./utils/DecimalMath.sol";
import "hardhat/console.sol";


contract Treasury is ITreasury, Orchestrated(), DecimalMath {
    using SafeCast for uint256;

    bytes32 constant WETH = "ETH-A";

    IWeth public override weth;
    GemJoinAbstract public override wethJoin;
    DaiAbstract public override dai;
    DaiJoinAbstract public override daiJoin;
    IChai public override chai;
    PotAbstract public override pot;    

    VatAbstract public override vat;

    constructor (
        address vat_,
        address weth_,
        address wethJoin_,
        address dai_,
        address daiJoin_,
        address chai_,
        address pot_
    ) {
        weth = IWeth(weth_);
        wethJoin = GemJoinAbstract(wethJoin_); // adapter of the valt for ERC20
        dai = DaiAbstract(dai_);
        chai = IChai(chai_);
        daiJoin = DaiJoinAbstract(daiJoin_);
        pot = PotAbstract(pot_);
        vat = VatAbstract(vat_);
        vat.hope(wethJoin_); // add gemJoin contract to talk for me to Vault engine
        vat.hope(daiJoin_); // add gemJoin contract to talk for me to Vault engine

        weth.approve(address(wethJoin), type(uint256).max); // weth we trust
        dai.approve(address(daiJoin), type(uint256).max); // dai we trust
    }

    function pushWeth(address from, uint256 amountWeth)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        require(weth.transferFrom(from, address(this), amountWeth));
        // GemJoin reverts if anything goes wrong
        wethJoin.join(address(this), amountWeth);
        // All added collateral should be locked into the vault using frob
        vat.frob(
            WETH,
            address(this),
            address(this),
            address(this),
            amountWeth.toInt256(),// Collateral to add
            0                       // No DAI to receive
        );
    }

    function pullWeth(address to, uint256 amountWeth)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {

        // Remove collateral from vault using frob
        vat.frob(
            WETH,
            address(this),
            address(this),
            address(this),
            -amountWeth.toInt256(), // Weth collateral to retrieve
            0                       // No DAI to add
        );

        // `GemJoin` reverts on failures
        // sends directly to `to`
        wethJoin.exit(to, amountWeth);
    }


    /// @dev Takes dai from user and pays as much system debt as possible, saving the rest as chai.
    /// User needs to have approved Treasury to take the Dai.
    /// This function can only be called by other Yield contracts, not users directly.
    /// @param from Wallet to take Dai from.
    /// @param amountDai Dai quantity to take.
    function pushDai(address from, uint256 amountDai)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        require(dai.transferFrom(from, address(this), amountDai));  // Take dai from user to Treasury

        // Due to the DSR being mostly lower than the SF, it is better for us to
        // immediately pay back as much as possible from the current debt to
        // minimize our future stability fee liabilities. If we didn't do this,
        // the treasury would simultaneously owe DAI (and need to pay the SF) and
        // hold Chai, which is inefficient.
        uint256 toRepay = Math.min(debt(), amountDai);
        if (toRepay > 0) {
            daiJoin.join(address(this), toRepay);
            // Remove debt from vault using frob
            (, uint256 rate,,,) = vat.ilks(WETH); // Retrieve the MakerDAO stability fee
            vat.frob(
                WETH,
                address(this),
                address(this),
                address(this),
                0,                                     // Weth collateral to add
                -divd(toRepay, rate).toInt256()        // Dai debt to remove
            );
        }

        uint256 toSave = amountDai - toRepay;         // toRepay can't be greater than dai
        if (toSave > 0) {
            chai.join(address(this), toSave);           // Give dai to Chai, take chai back
        }
    }

    /// @dev Returns dai using chai savings as much as possible, and borrowing the rest.
    /// This function can only be called by other Yield contracts, not users directly.
    /// @param to Wallet to send Dai to.
    /// @param amountDai Dai quantity to send.
    function pullDai(address to, uint256 amountDai)
        public override
        onlyOrchestrated("Treasury: Not Authorized")
    {
        uint256 toRelease = Math.min(savings(), amountDai);
        if (toRelease > 0) {
            chai.draw(address(this), toRelease);     // Grab dai from Chai, converted from chai
        }

        uint256 toBorrow = amountDai - toRelease;    // toRelease can't be greater than dai
        if (toBorrow > 0) {
            (, uint256 rate,,,) = vat.ilks(WETH); // Retrieve the MakerDAO stability fee
            // Increase the dai debt by the dai to receive divided by the stability fee
            // `frob` deals with "normalized debt", instead of DAI.
            // "normalized debt" is used to account for the fact that debt grows
            // by the stability fee. The stability fee is accumulated by the "rate"
            // variable, so if you store Dai balances in "normalized dai" you can
            // deal with the stability fee accumulation with just a multiplication.
            // This means that the `frob` call needs to be divided by the `rate`
            // while the `GemJoin.exit` call can be done with the raw `toBorrow`
            // number.
            vat.frob(
                WETH,
                address(this),
                address(this),
                address(this),
                0,
                divdrup(toBorrow, rate).toInt256() // We need to round up, otherwise we won't exit toBorrow
            );
            daiJoin.exit(address(this), toBorrow); // `daiJoin` reverts on failures
        }

        dai.transfer(to, amountDai);            // Give dai to user - Dai doesn't have a return value for `transfer`
    }

    /// @dev Returns the Treasury debt towards MakerDAO, in Dai.
    /// We have borrowed (rate * art)
    /// Borrowing limit (rate * art) <= (ink * spot)
    function debt() public view override returns(uint256) {
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

        (, uint256 rate,,,) = vat.ilks(WETH);            // Retrieve the MakerDAO stability fee for Weth (ray)
        (, uint256 art) = vat.urns(WETH, address(this)); // Retrieve the Treasury debt in MakerDAO (wad)
        return muld(art, rate);
    }

    /// @dev Returns the amount of chai in this contract, converted to Dai.
    function savings() public view override returns(uint256){
        return muld(chai.balanceOf(address(this)), pot.chi());
    }

}
