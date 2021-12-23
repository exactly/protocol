// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

library TSUtils {
    enum State {
        NONE,
        INVALID,
        MATURED,
        VALID,
        NOT_READY
    }

    uint32 public constant INTERVAL = 7 days;

    /**
     * @notice Function to calculate how many days have passed between the two dates
     * @param timestampFrom to calculate the day difference
     * @param timestampTo to calculate the day difference
     */
    function daysPast(uint256 timestampFrom, uint256 timestampTo)
        public
        pure
        returns (uint256)
    {
        uint256 trimmedFrom = trimmedDay(timestampFrom);
        uint256 trimmedTo = trimmedDay(timestampTo);
        if (trimmedFrom > trimmedTo) {
            return (trimmedFrom - trimmedTo) / 1 days;
        } else {
            return 0;
        }
    }

    /**
     * @notice Function to calculate how many days are left to a certain date
     * @param timestampFrom to calculate the day difference
     * @param timestampTo to calculate the day difference
     */
    function daysPre(uint256 timestampFrom, uint256 timestampTo)
        public
        pure
        returns (uint256)
    {
        uint256 trimmedFrom = trimmedDay(timestampFrom);
        uint256 trimmedTo = trimmedDay(timestampTo);
        if (trimmedFrom < trimmedTo) {
            return (trimmedTo - trimmedFrom) / 1 days;
        } else {
            return 0;
        }
    }

    /**
     * @notice Function to take a timestamp to it's 00:00 hours (beginning of day)
     * @param timestamp timestamp to calculate the beginning of the day with
     */
    function trimmedDay(uint256 timestamp) public pure returns (uint256) {
        return timestamp - (timestamp % 1 days);
    }

    /**
     * @notice Function to return a pool _time_ state based on the current time,
     *         maxPools available, and the INTERVALS configured, all to return
     *         if a pool is VALID, not yet available(NOT_READY), INVALID or MATURED
     * @param currentTimestamp timestamp of the current time
     * @param timestamp used as POOLID
     * @param maxPools number of pools available in the time horizon to be available
     */
    function getPoolState(
        uint256 currentTimestamp,
        uint256 timestamp,
        uint8 maxPools
    ) public pure returns (State) {
        if (timestamp % INTERVAL != 0) {
            return State.INVALID;
        }

        if (timestamp < currentTimestamp) {
            return State.MATURED;
        }

        uint256 totalSecondsForEnabledPools = INTERVAL * maxPools;
        if (
            timestamp >
            currentTimestamp -
                (currentTimestamp % INTERVAL) +
                totalSecondsForEnabledPools
        ) {
            return State.NOT_READY;
        }

        return State.VALID;
    }

    /**
     * @notice Function that validates if a certain timestamp is a POOLID based on the INTERVALS
     *         configured for this library
     * @param timestamp to validate if is a POOLID
     */
    function isPoolID(uint256 timestamp) public pure returns (bool) {
        return (timestamp % INTERVAL) == 0;
    }

    /**
     * @notice Function to return all the future pool IDs give in a certain time horizon that
     *         gets calculated using a startTime, the amount of pools to returns, and the INTERVAL
     *         configured in this library
     * @param startingTimestamp initialTimestamp to start calculating poolIDs
     * @param maxPools number of pools to return
     */
    function futurePools(uint256 startingTimestamp, uint8 maxPools)
        public
        pure
        returns (uint256[] memory)
    {
        uint256[] memory poolIDs = new uint256[](maxPools);
        uint256 timestamp = startingTimestamp - (startingTimestamp % INTERVAL);
        for (uint256 i = 0; i < maxPools; i++) {
            timestamp += INTERVAL;
            poolIDs[i] = timestamp;
        }
        return poolIDs;
    }
}
