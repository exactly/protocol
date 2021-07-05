// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./interfaces/ITreasury.sol";
import "./utils/Orchestrated.sol";
import "hardhat/console.sol";

contract Treasury is ITreasury, Orchestrated() {
    using SafeCast for uint256;

    bytes32 constant WETH = "ETH-A";

    IWeth public override weth;
    GemJoinAbstract public override wethJoin;
    VatAbstract public override vat;

    constructor (
        address vat_,
        address weth_,
        address wethJoin_
    ) {
        weth = IWeth(weth_);
        wethJoin = GemJoinAbstract(wethJoin_); // adapter of the valt for ERC20
        vat = VatAbstract(vat_);
        vat.hope(wethJoin_); // add gemJoin contract to talk for me to Vault engine

        weth.approve(address(wethJoin), type(uint256).max); // weth we trust
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
            amountWeth.toInt256(), // Collateral to add
            0                      // No DAI to receive
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
}
