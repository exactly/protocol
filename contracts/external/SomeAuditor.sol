// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/DecimalMath.sol";
import "../utils/ExaLib.sol";

contract SomeAuditor {

    using DecimalMath for uint256;
    using ExaLib for ExaLib.RewardsState;

    uint256 public blockNumber;

    // Rewards Management
    ExaLib.RewardsState public rewardsState;

    constructor(address _exaToken) {
        rewardsState.exaToken = _exaToken;
    }

    function setBlockNumber(uint256 _blockNumber) public {
        blockNumber = _blockNumber;
    }

    /**
     * @notice Set EXA speed for a single market
     * @param exafinAddress The market whose EXA speed to update
     * @param exaSpeed New EXA speed for market
     */
    function setExaSpeed(address exafinAddress, uint256 exaSpeed) external {
        require(
            rewardsState.setExaSpeed(blockNumber, exafinAddress, exaSpeed) == true,
            "Error setExaSpeed"
        );
    }

    /**
     * @dev Function to retrieve supply state for rewards
     */
    function getSupplyState(address exafinAddress) public view returns (MarketRewardsState memory) {
        return rewardsState.exaState[exafinAddress].exaSupplyState;
    }

    /**
     * @dev Function to retrieve supply state for rewards
     */
    function getBorrowState(address exafinAddress) public view returns (MarketRewardsState memory) {
        return rewardsState.exaState[exafinAddress].exaBorrowState;
    }

    /**
     * @dev Function to update state re: borrow index
     */
    function updateExaBorrowIndex(address exafinAddress) external  {
        rewardsState.updateExaBorrowIndex(blockNumber, exafinAddress);
    }

    /**
     * @dev Function to update state re: supply index
     */
    function updateExaSupplyIndex(address exafinAddress) external  {
        rewardsState.updateExaSupplyIndex(blockNumber, exafinAddress);
    }

}
