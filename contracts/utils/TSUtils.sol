// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

library TSUtils {

    uint32 public constant INTERVAL = 7 days;

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
        if (timestamp % INTERVAL != 0) {
            return State.INVALID;
        }

        if (timestamp < currentTimestamp) {
            return State.MATURED;
        }

        uint256 totalSecondsForEnabledPools = INTERVAL * maxPools;
        if (timestamp > currentTimestamp - (currentTimestamp % INTERVAL) + totalSecondsForEnabledPools) {
            return State.NOT_READY;
        }

        return State.VALID;
    }

    function isPoolID(uint256 timestamp) public pure returns (bool) {
        return (timestamp % INTERVAL) == 0;
    }

    function futurePools(uint256 startingTimestamp, uint8 maxPools) public pure returns (uint256[] memory) {
        uint256[] memory poolIDs = new uint256[](maxPools);
        uint256 timestamp = startingTimestamp - (startingTimestamp % INTERVAL);
        for (uint256 i=0; i < maxPools; i++) {
            timestamp += INTERVAL;
            poolIDs[i] = timestamp;
        }
        return poolIDs;
    }
}

