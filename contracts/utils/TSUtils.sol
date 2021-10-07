// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "hardhat/console.sol";

library TSUtils {
    function trimmedDay(uint256 timestamp) public pure returns (uint256) {
        return timestamp - (timestamp % 86400);
    }

    function isPoolID(uint256 timestamp) public pure returns (bool) {
        return (timestamp % 14 days) == 0;
    }

    function futurePools(uint256 startingTimestamp, uint8 maxPools) public pure returns (uint256[] memory) {
        uint256[] memory poolIDs = new uint256[](maxPools);
        uint256 timestamp = startingTimestamp - (startingTimestamp % 14 days);
        for (uint i=0; i < maxPools; i++) {
            timestamp += 14 days;
            poolIDs[i] = timestamp;
        }
        return poolIDs;
    }
}
