// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "hardhat/console.sol";

library TSUtils {

    enum State {
        INVALID,
        MATURED,
        VALID,
        NOT_READY
    }

    function trimmedDay(uint256 timestamp) public pure returns (uint256) {
        return timestamp - (timestamp % 1 days);
    }

    function getPoolState(uint256 currentTimestamp, uint256 timestamp, uint8 maxPools) public pure returns (State) {
        if (timestamp % 14 days != 0) {
            return State.INVALID;
        }

        if (timestamp < currentTimestamp) {
            return State.MATURED;
        }

        uint256 totalSecondsForEnabledPools = 14 days * maxPools;
        if (timestamp > currentTimestamp - (currentTimestamp % 14 days) + totalSecondsForEnabledPools) {
            return State.NOT_READY;
        }

        return State.VALID;
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
