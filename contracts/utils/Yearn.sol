// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DecimalMath} from "./DecimalMath.sol";
import "hardhat/console.sol";
import "./IyDAI.sol";

library Yearn {

    using SafeCast for uint256;

    struct Adapters {
        IyDAI ydai;
    }

    /// @dev Returns the Treasury's savings in yEarn, in Dai.
    function savingsInDai(Adapters memory adapter, address who) internal view returns (uint256) {
        return adapter.ydai.balanceOf(who) * adapter.ydai.getPricePerFullShare();
    }

    /// @dev Brings Dai to Exactly
    function withdraw(Adapters memory adapter, uint256 amountDai) internal {
        uint256 amountInShares = amountDai / adapter.ydai.getPricePerFullShare();
        return adapter.ydai.withdraw(amountInShares);
    }

    /// @dev Brings Dai to Exactly
    function deposit(Adapters memory adapter, uint256 amountDai) internal {
        adapter.ydai.deposit(amountDai);
    }
}