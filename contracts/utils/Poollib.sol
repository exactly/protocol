// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

library PoolLib {

    struct Pool {
        uint256 borrowed;
        uint256 supplied;
    }

    struct AssetSource {
        uint256 fromPool;
        uint256 fromPot;
    }

    function borrowAdd(Pool calldata pool, uint256 amountBorrow) internal pure returns (AssetSource memory) {
        AssetSource memory assetSource;

        uint256 newBorrow = pool.borrowed + amountBorrow;

        // if the new borrow is still under the supplied money
        if (newBorrow <= pool.supplied) {
            assetSource.fromPool = amountBorrow;
        
        // if the previous borrowed amount was already bigger than the supplied money
        } else if (pool.borrowed >= pool.supplied) {
            assetSource.fromPot = amountBorrow;

        // if the amount of borrowed money needs to be taken a bit from the pool
        // and the rest from the pot
        } else {
            assetSource.fromPool = pool.supplied - pool.borrowed;
            assetSource.fromPot = amountBorrow - assetSource.fromPool;
        }

        return assetSource;
    }
}
