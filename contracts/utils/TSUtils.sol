// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./Errors.sol";

library TSUtils {
    enum State {
        NONE,
        INVALID,
        MATURED,
        VALID,
        NOT_READY
    }

    uint32 public constant INTERVAL = 7 days;
    uint8 public constant MAX_FUTURE_POOLS = 12; // if every 14 days, then 6 months

    /**
     * @notice Function to return all the future pool IDs give in a certain time horizon that
     *         gets calculated using a startTime, the amount of pools to returns, and the INTERVAL
     *         configured in this library
     */
    function futurePools() public view returns (uint256[] memory) {
        uint256[] memory poolIDs = new uint256[](MAX_FUTURE_POOLS);
        uint256 timestamp = block.timestamp - (block.timestamp % INTERVAL);
        for (uint256 i = 0; i < MAX_FUTURE_POOLS; i++) {
            timestamp += INTERVAL;
            poolIDs[i] = timestamp;
        }
        return poolIDs;
    }

    /**
     * @notice Function to calculate how many seconds are left to a certain date
     * @param timestampFrom to calculate the difference in seconds from a date
     * @param timestampTo to calculate the difference in seconds to a date
     */
    function secondsPre(uint256 timestampFrom, uint256 timestampTo)
        public
        pure
        returns (uint256)
    {
        return timestampFrom < timestampTo ? timestampTo - timestampFrom : 0;
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
     * @dev Function to verify that a maturityDate is VALID, MATURED, NOT_READY or INVALID.
     *      If expected state doesn't match the calculated one, it reverts with a custom error "UnmatchedPoolState".
     * @param maturityDate timestamp of the maturity date to be verified
     * @param requiredState state required by the caller to be verified (see TSUtils.State() for description)
     * @param alternativeState state required by the caller to be verified (see TSUtils.State() for description)
     */
    function requirePoolState(
        uint256 maturityDate,
        TSUtils.State requiredState,
        TSUtils.State alternativeState
    ) internal view {
        TSUtils.State poolState = getPoolState(
            block.timestamp,
            maturityDate,
            MAX_FUTURE_POOLS
        );

        if (poolState != requiredState && poolState != alternativeState) {
            if (alternativeState == TSUtils.State.NONE) {
                revert UnmatchedPoolState(poolState, requiredState);
            }
            revert UnmatchedPoolStateMultiple(
                poolState,
                requiredState,
                alternativeState
            );
        }
    }
}
