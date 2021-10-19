// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./interfaces/IInterestRateModel.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/TSUtils.sol";
import "./utils/Errors.sol";
import "./utils/DecimalMath.sol";

import "hardhat/console.sol";


contract DefaultInterestRateModel is IInterestRateModel, AccessControl {
    using PoolLib for PoolLib.Pool;

    bytes32 public constant TEAM_ROLE = keccak256("TEAM_ROLE");

    // Parameters to the system, expressed with 1e18 decimals
    uint256 public marginRate;
    uint256 public mpSlopeRate;
    uint256 public spSlopeRate;
    using DecimalMath for uint256;

    constructor(uint256 _marginRate, uint256 _slopeRate) {
        marginRate = _marginRate;
        mpSlopeRate = _slopeRate;
        spSlopeRate = _slopeRate;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(TEAM_ROLE, msg.sender);
    }

    /**
        @dev Function to update this model's parameters (TEAM_ONLY)
        @param _marginRate spread between borrowing and lending
        @param _slopeRate slope to alter the utilization rate
     */
    function setParameters(uint256 _marginRate, uint256 _slopeRate) external onlyRole(TEAM_ROLE) {
        marginRate = _marginRate;
        mpSlopeRate = _slopeRate;
        spSlopeRate = _slopeRate;
    }

    /**
        @dev Get current rate for borrow a certain amount in a certain maturity
             with supply/demand values in the maturity pool and supply demand values
             in the pot
        @param amount amount to borrow from a certain maturity date
        @param maturityDate maturity date for calculating days left to maturity
        @param maturityPool supply/demand values for the maturity pool
        @param smartPool supply/demand values for the smartPool
     */
    function getRateToBorrow(
        uint256 amount,
        uint256 maturityDate,
        PoolLib.Pool memory maturityPool,
        PoolLib.SmartPool memory smartPool,
        bool newDebt
    ) override external view returns (uint256) {
        if(!TSUtils.isPoolID(maturityDate)) revert GenericError(ErrorCode.INVALID_POOL_ID);
        uint256 yearlyRate = 0;

        if (maturityPool.borrowed == 0 || maturityPool.supplied == 0) {
            console.log("Pool: Division by zero");
        } else {
            console.log('Previo maturity', maturityPool.borrowed, maturityPool.supplied);
            yearlyRate = (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;
            console.log("1 yearlyRate getRateToBorrow", yearlyRate);
        }

        console.log('Previo smart', smartPool.borrowed, smartPool.supplied);
        if (smartPool.borrowed == 0 || smartPool.supplied == 0) {
            console.log("SmartPool: Division by zero");
        } else {
            if (newDebt && (maturityPool.borrowed == 0 || maturityPool.supplied == 0)) {
                console.log('Smart pool balances before smart pool yearly rate', smartPool.borrowed, smartPool.supplied);
                yearlyRate = (spSlopeRate * smartPool.borrowed) / smartPool.supplied;

                console.log("1.5 yearlyRate getRateToBorrow", yearlyRate);
            }

            if (newDebt && maturityPool.borrowed != 0 && maturityPool.supplied != 0 && smartPool.borrowed.div_(smartPool.supplied) > maturityPool.borrowed.div_(maturityPool.supplied)) {
                yearlyRate = (spSlopeRate * smartPool.borrowed) / smartPool.supplied;
                console.log("2 yearlyRate getRateToBorrow", yearlyRate);
            }
        }

        console.log("3 yearlyRate getRateToBorrow", yearlyRate);
        maturityPool.borrowed += amount;


        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;

        return ((yearlyRate * daysDifference) / 365);

    }

    /**
        @dev Get current rate for supplying a certain amount in a certain maturity
             with supply/demand values in the maturity pool and supply demand values
             in the pot
        @param amount amount to supply to a certain maturity date
        @param maturityDate maturity date for calculating days left to maturity
        @param maturityPool supply/demand values for the maturity pool
        @param smartPool supply/demand values for the smart pool
     */
    function getRateToSupply(
        uint256 amount,
        uint256 maturityDate,
        PoolLib.Pool memory maturityPool,
        PoolLib.SmartPool memory smartPool
    ) override external view returns (uint256) {
        if(!TSUtils.isPoolID(maturityDate)) revert GenericError(ErrorCode.INVALID_POOL_ID);

        uint256 yearlyRate = 0;

        if (maturityPool.borrowed == 0 || maturityPool.supplied == 0) {
            console.log("Pool: Division by zero");
        } else {
            yearlyRate = (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;
            console.log("1 yearlyRate getRateToSupply", yearlyRate);
        }

        if (smartPool.borrowed == 0 || smartPool.supplied == 0) {
            console.log("SmartPool: Division by zero");
        } else {
            // uint256 maturityEq = (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;
            uint256 smartEq =  ((spSlopeRate * smartPool.borrowed) / smartPool.supplied) + maturityPool.supplied + amount;

            if (maturityPool.borrowed == 0 || maturityPool.supplied == 0) {
                yearlyRate = smartEq;
                console.log("2 yearlyRate getRateToSupply", yearlyRate);
            }
        }

        maturityPool.supplied += amount;

        console.log("3 yearlyRate getRateToSupply", yearlyRate);
        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;

        // uint256 yearlyRate = (slopeRate * utilizationRate);

        return ((yearlyRate * daysDifference) / 365);
    }
}
