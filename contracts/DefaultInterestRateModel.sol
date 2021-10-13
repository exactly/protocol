// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./interfaces/IInterestRateModel.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/TSUtils.sol";
import "./utils/Errors.sol";

contract DefaultInterestRateModel is IInterestRateModel, AccessControl {
    using PoolLib for PoolLib.Pool;

    bytes32 public constant TEAM_ROLE = keccak256("TEAM_ROLE");

    // Parameters to the system, expressed with 1e18 decimals
    uint256 public marginRate;
    uint256 public slopeRate;

    constructor(uint256 _marginRate, uint256 _slopeRate) {
        marginRate = _marginRate;
        slopeRate = _slopeRate;
        _setupRole(TEAM_ROLE, msg.sender);
    }

    /**
        @dev Function to update this model's parameters (TEAM_ONLY)
        @param _marginRate spread between borrowing and lending
        @param _slopeRate slope to alter the utilization rate
     */
    function setParameters(uint256 _marginRate, uint256 _slopeRate) external onlyRole(TEAM_ROLE) {
        marginRate = _marginRate;
        slopeRate = _slopeRate;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(TEAM_ROLE, msg.sender);
    }

    /**
        @dev Get current rate for borrow a certain amount in a certain maturity
             with supply/demand values in the maturity pool and supply demand values
             in the pot
        @param amount amount to borrow from a certain maturity date
        @param maturityDate maturity date for calculating days left to maturity
        @param maturityPool supply/demand values for the maturity pool
        @param potPool supply/demand values for the pot
     */
    function getRateToBorrow(
        uint256 amount,
        uint256 maturityDate,
        PoolLib.Pool memory maturityPool,
        PoolLib.Pool memory potPool
    ) override external view returns (uint256) {

        if(!TSUtils.isPoolID(maturityDate)) revert GenericError(ErrorCode.INVALID_POOL_ID);

        maturityPool.borrowed += amount;

        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;
        uint256 yearlyRate = marginRate +
            ((slopeRate * maturityPool.borrowed) / maturityPool.supplied);

        return ((yearlyRate * daysDifference) / 365);

    }

    /**
        @dev Get current rate for supplying a certain amount in a certain maturity
             with supply/demand values in the maturity pool and supply demand values
             in the pot
        @param amount amount to supply to a certain maturity date
        @param maturityDate maturity date for calculating days left to maturity
        @param maturityPool supply/demand values for the maturity pool
        @param potPool supply/demand values for the pot
     */
    function getRateToSupply(
        uint256 amount,
        uint256 maturityDate,
        PoolLib.Pool memory maturityPool,
        PoolLib.Pool memory potPool
    ) override external view returns (uint256) {

        if(!TSUtils.isPoolID(maturityDate)) revert GenericError(ErrorCode.INVALID_POOL_ID);

        maturityPool.supplied += amount;

        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;

        uint256 yearlyRate = ((slopeRate * maturityPool.borrowed) / maturityPool.supplied);

        return ((yearlyRate * daysDifference) / 365);
    }

}
