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

    function canCalculateSmartPoolUR(PoolLib.SmartPool memory smartPool) pure internal returns (bool) {
        return smartPool.borrowed != 0 && smartPool.supplied != 0;
    }

     function canCalculateMaturityPoolUR(PoolLib.Pool memory maturityPool) pure internal returns (bool) {
        return maturityPool.borrowed != 0 && maturityPool.supplied != 0;
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
        
        bool canCheckSmartPoolUR = canCalculateSmartPoolUR(smartPool);
        bool canCheckMaturityPoolUR = canCalculateMaturityPoolUR(maturityPool);

        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;

        uint256 yearlyRate = 0;
        uint256 maturityPoolYearlyRate = 0;
        uint256 smartPoolYearlyRate = 0;

        if (!canCheckSmartPoolUR && !canCheckMaturityPoolUR) {
            console.log('Final return', 0);
            return 0;
        }

        if (canCheckSmartPoolUR) {
            smartPoolYearlyRate = (spSlopeRate * smartPool.borrowed) / smartPool.supplied;
        }

        if (canCheckMaturityPoolUR) {
            maturityPoolYearlyRate = (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;
        }

        if (!newDebt) {
            yearlyRate = maturityPoolYearlyRate;
            console.log('Final return', yearlyRate);

            return ((yearlyRate * daysDifference) / 365);
        }

        //This conditionals are just for testing, will delete later.
        if (smartPoolYearlyRate > maturityPoolYearlyRate) {
            console.log('Final return', smartPoolYearlyRate);
        } else {
            console.log('Final return', maturityPoolYearlyRate);
        }

        return smartPoolYearlyRate > maturityPoolYearlyRate ? ((smartPoolYearlyRate * daysDifference) / 365) : ((maturityPoolYearlyRate * daysDifference) / 365);
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
        uint256 maturityPoolYearlyRate = 0;
        uint256 smartPoolYearlyRate = 0;

        bool canCheckSmartPoolUR = canCalculateSmartPoolUR(smartPool);
        bool canCheckMaturityPoolUR = canCalculateMaturityPoolUR(maturityPool);
        

        if (canCheckSmartPoolUR) {
            smartPoolYearlyRate = ((spSlopeRate * smartPool.borrowed) / (smartPool.supplied + amount));
        }

        if (canCheckMaturityPoolUR) {
            maturityPoolYearlyRate = (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;
        }

        if (!canCheckMaturityPoolUR && !canCheckSmartPoolUR) {
            console.log('Final return getRateToSupply', 0);

            return 0;
        }

        if (canCheckMaturityPoolUR && maturityPool.supplied - maturityPool.borrowed != 0) {
            yearlyRate = maturityPoolYearlyRate;
        }

        if (canCheckSmartPoolUR && !canCheckMaturityPoolUR || maturityPool.supplied - maturityPool.borrowed == 0) {
            yearlyRate = smartPoolYearlyRate;
        }

        console.log("Final yearlyRate getRateToSupply", yearlyRate);
        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;

        return ((yearlyRate * daysDifference) / 365);
    }
}
