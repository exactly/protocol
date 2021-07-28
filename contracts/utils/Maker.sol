// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "dss-interfaces/src/dss/GemJoinAbstract.sol";
import "dss-interfaces/src/dss/DaiJoinAbstract.sol";
import "dss-interfaces/src/dss/VatAbstract.sol";
import {DecimalMath} from "./DecimalMath.sol";
import "hardhat/console.sol";

interface MakerAdaptersProvider { 
    function makerAdapters() external view returns (Maker.Adapters memory);
}

library Maker {
    bytes32 constant WETH = "ETH-A";
    uint256 public constant UNIT = 1e27; // RAY (27 decimals)

    using SafeCast for uint256;

    struct Adapters {
        GemJoinAbstract wethJoin;
        DaiJoinAbstract daiJoin;
        VatAbstract vat;
    }

    function getAdapters() internal view returns (Maker.Adapters memory) {
        return MakerAdaptersProvider(address(this)).makerAdapters();
    }

    /// @dev Returns the Treasury debt towards MakerDAO, in Dai.
    /// We have borrowed (rate * art)
    /// Borrowing limit (rate * art) <= (ink * spot)
    function debtFor(address who) internal view returns (uint256) {
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
        (, uint256 rate,,,) = getAdapters().vat.ilks(WETH);  // Retrieve the MakerDAO stability fee for Weth (ray)
        (, uint256 art) = getAdapters().vat.urns(WETH, who); // Retrieve the Treasury debt in MakerDAO (wad)
        return DecimalMath.muld(art, rate);
    }

    function addWeth(uint256 amountWeth) internal {
        // GemJoin reverts if anything goes wrong
        getAdapters().wethJoin.join(address(this), amountWeth);
        // All added collateral should be locked into the vault using frob
        getAdapters().vat.frob(
            WETH,
            address(this),
            address(this),
            address(this),
            amountWeth.toInt256(),// Collateral to add
            0                     // No DAI to receive
        );
    }

    function retrieveWeth(uint256 amountWeth, address to) internal {
        // Remove collateral from vault using frob
        getAdapters().vat.frob(
            WETH,
            address(this),
            address(this),
            address(this),
            -amountWeth.toInt256(), // Weth collateral to retrieve
            0                       // No DAI to add
        );

        // `GemJoin` reverts on failures
        // sends directly to `to`
        getAdapters().wethJoin.exit(to, amountWeth);
    }

    function returnDai(uint256 amountDai) internal {
        getAdapters().daiJoin.join(address(this), amountDai);
        // Remove debt from vault using frob
        (, uint256 rate,,,) = getAdapters().vat.ilks(WETH);// Retrieve the MakerDAO stability fee
        getAdapters().vat.frob(
            WETH,
            address(this),
            address(this),
            address(this),
            0,                                             // Weth collateral to add
            -DecimalMath.divd(amountDai, rate).toInt256()  // Dai debt to remove
        );
    }

    function retrieveDai(uint256 amountDai, address destination) internal {
        (, uint256 rate,,,) = getAdapters().vat.ilks(WETH); // Retrieve the MakerDAO stability fee
            // Increase the dai debt by the dai to receive divided by the stability fee
            // `frob` deals with "normalized debt", instead of DAI.
            // "normalized debt" is used to account for the fact that debt grows
            // by the stability fee. The stability fee is accumulated by the "rate"
            // variable, so if you store Dai balances in "normalized dai" you can
            // deal with the stability fee accumulation with just a multiplication.
            // This means that the `frob` call needs to be divided by the `rate`
            // while the `GemJoin.exit` call can be done with the raw `toBorrow`
            // number.
        getAdapters().vat.frob(
                WETH,
                address(this),
                address(this),
                address(this),
                0,
                DecimalMath.divdrup(amountDai, rate).toInt256() // We need to round up, otherwise we won't exit toBorrow
            );
        getAdapters().daiJoin.exit(destination, amountDai);   // `daiJoin` reverts on failures
    }

    function ethPriceInDai(uint256 amountWeth) internal view returns (uint256) { 
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
        // dai = (collateral (ie: 1ETH) * price (ie: 2200 DAI/ETH)) / 1e27(RAD->RAY)
        (,, uint256 spot,,) = getAdapters().vat.ilks(WETH);
        return (amountWeth * spot) / (UNIT);
    }
}