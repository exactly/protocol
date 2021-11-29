// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

/**
 * @title IChainlinkFeedRegistry
 * @notice The interface of an on-chain registry of assets to price aggregators
 */
interface IChainlinkFeedRegistry {
    /**
     * @notice Get data about the latest round
     * @param base Base asset address
     * @param quote Quote asset address
     * @return roundId is the round ID from the aggregator for which the data was
     *         retrieved combined with a phase to ensure that round IDs get larger as
     *         time moves forward. Not currently in use
     * @return answer is the answer for the given round
     * @return startedAt is the timestamp when the round was started. Not currently in use
     *         (Only some AggregatorV3Interface implementations return meaningful values)
     * @return updatedAt is the timestamp when the round last was updated.
     *         (i.e. answer was last computed)
     * @return answeredInRound is the round ID of the round in which the answer
     *         was computed. Not currently in use
     *         (Only some AggregatorV3Interface implementations return meaningful values)
     * @dev Note that answer and updatedAt may change between queries.
     */
    function latestRoundData(address base, address quote)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
