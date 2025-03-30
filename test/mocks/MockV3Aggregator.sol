// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockV3Aggregator
 * @notice This is a mock contract for simulating Chainlink price feeds in testing environments.
 * @dev It allows developers to set and update price values manually without relying on real-world data.
 */
contract MockV3Aggregator {
    uint256 public constant version = 0; // Version number for reference

    uint8 public decimals; // Number of decimal places for the price feed
    int256 public latestAnswer; // Latest price feed value
    uint256 public latestTimestamp; // Timestamp of the latest price update
    uint256 public latestRound; // Latest round ID

    mapping(uint256 => int256) public getAnswer; // Mapping of round ID to price value
    mapping(uint256 => uint256) public getTimestamp; // Mapping of round ID to timestamp
    mapping(uint256 => uint256) private getStartedAt; // Mapping of round ID to start timestamp

    /**
     * @notice Initializes the mock price feed with a given decimal precision and initial price.
     * @param _decimals The number of decimal places for the price values.
     * @param _initialAnswer The initial price value to be set.
     */
    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        updateAnswer(_initialAnswer);
    }

    /**
     * @notice Updates the latest price value and timestamps.
     * @param _answer The new price value to set.
     */
    function updateAnswer(int256 _answer) public {
        latestAnswer = _answer;
        latestTimestamp = block.timestamp;
        latestRound++;
        getAnswer[latestRound] = _answer;
        getTimestamp[latestRound] = block.timestamp;
        getStartedAt[latestRound] = block.timestamp;
    }

    /**
     * @notice Manually updates round data for a specific round ID.
     * @param _roundId The round ID to update.
     * @param _answer The price value for the round.
     * @param _timestamp The timestamp for the update.
     * @param _startedAt The timestamp when the round started.
     */
    function updateRoundData(
        uint80 _roundId,
        int256 _answer,
        uint256 _timestamp,
        uint256 _startedAt
    ) public {
        latestRound = _roundId;
        latestAnswer = _answer;
        latestTimestamp = _timestamp;
        getAnswer[latestRound] = _answer;
        getTimestamp[latestRound] = _timestamp;
        getStartedAt[latestRound] = _startedAt;
    }

    /**
     * @notice Retrieves historical round data for a given round ID.
     * @param _roundId The round ID to retrieve data for.
     * @return roundId The round ID.
     * @return answer The price value at that round.
     * @return startedAt The start timestamp of the round.
     * @return updatedAt The timestamp of the latest update.
     * @return answeredInRound The round in which the answer was provided.
     */
    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            _roundId,
            getAnswer[_roundId],
            getStartedAt[_roundId],
            getTimestamp[_roundId],
            _roundId
        );
    }

    /**
     * @notice Retrieves the latest round data available.
     * @return roundId The latest round ID.
     * @return answer The latest price value.
     * @return startedAt The start timestamp of the latest round.
     * @return updatedAt The timestamp of the latest update.
     * @return answeredInRound The round in which the latest answer was provided.
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            uint80(latestRound),
            getAnswer[latestRound],
            getStartedAt[latestRound],
            getTimestamp[latestRound],
            uint80(latestRound)
        );
    }

    /**
     * @notice Provides a static description of the contract for reference.
     * @return A string containing the description.
     */
    function description() external pure returns (string memory) {
        return "v0.6/tests/MockV3Aggregator.sol";
    }
}
