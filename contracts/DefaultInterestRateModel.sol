// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./interfaces/IInterestRateModel.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/TSUtils.sol";
import "./utils/Errors.sol";
import "./utils/DecimalMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "hardhat/console.sol";

contract DefaultInterestRateModel is IInterestRateModel, AccessControl {
    using PoolLib for PoolLib.Pool;

    bytes32 public constant TEAM_ROLE = keccak256("TEAM_ROLE");

    // Parameters to the system, expressed with 1e18 decimals
    uint256 public marginRate;
    uint256 public mpSlopeRate;
    uint256 public spSlopeRate;
    using DecimalMath for uint256;

    constructor(
        uint256 _marginRate,
        uint256 _mpSlopeRate,
        uint256 _spSlopeRate
    ) {
        marginRate = _marginRate;
        mpSlopeRate = _mpSlopeRate;
        spSlopeRate = _spSlopeRate;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(TEAM_ROLE, msg.sender);
    }

    /**
        @dev Function to update this model's parameters (TEAM_ONLY)
        @param _marginRate spread between borrowing and lending
        @param _mpSlopeRate slope to alter the utilization rate
        @param _spSlopeRate slope to alter the utilization rate
     */
    function setParameters(
        uint256 _marginRate,
        uint256 _mpSlopeRate,
        uint256 _spSlopeRate
    ) external onlyRole(TEAM_ROLE) {
        marginRate = _marginRate;
        mpSlopeRate = _mpSlopeRate;
        spSlopeRate = _spSlopeRate;
    }

    function canCalculateSmartPoolUR(PoolLib.SmartPool memory smartPool) internal pure returns (bool) {
        return smartPool.borrowed != 0 && smartPool.supplied != 0;
    }

    function canCalculateMaturityPoolUR(PoolLib.Pool memory maturityPool) internal pure returns (bool) {
        return maturityPool.borrowed != 0 && maturityPool.supplied != 0;
    }

    /**
        @dev Get current rate for borrow a certain amount in a certain maturity
             with supply/demand values in the maturity pool and supply demand values
             in the pot
        @param maturityDate maturity date for calculating days left to maturity
        @param maturityPool supply/demand values for the maturity pool
        @param smartPool supply/demand values for the smartPool
     */
    function getRateToBorrow(
        uint256 maturityDate,
        PoolLib.Pool memory maturityPool,
        PoolLib.SmartPool memory smartPool,
        bool newDebt
    ) external view override returns (uint256) {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        bool canCheckSmartPoolUR = canCalculateSmartPoolUR(smartPool);
        bool canCheckMaturityPoolUR = canCalculateMaturityPoolUR(maturityPool);

        uint256 daysDifference = (maturityDate - TSUtils.trimmedDay(block.timestamp)) / 1 days;

        uint256 yearlyRate = 0;

        if (!canCheckSmartPoolUR && !canCheckMaturityPoolUR) {
            return 0;
        }

        if (!newDebt) {
            yearlyRate = maturityPool.supplied == 0 ? 0 : (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;
        } else {
            yearlyRate = Math.max(
                smartPool.supplied == 0 ? 0 : (spSlopeRate * smartPool.borrowed) / smartPool.supplied,
                maturityPool.supplied == 0 ? 0 : (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied
            );
        }

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
    ) external view override returns (uint256) {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

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
            return 0;
        }

        if (canCheckMaturityPoolUR && maturityPool.supplied - maturityPool.borrowed != 0) {
            yearlyRate = maturityPoolYearlyRate;
        }

        if ((canCheckSmartPoolUR && !canCheckMaturityPoolUR) || maturityPool.supplied - maturityPool.borrowed == 0) {
            yearlyRate = smartPoolYearlyRate;
        }

        uint256 daysDifference = (maturityDate - TSUtils.trimmedDay(block.timestamp)) / 1 days;

        return ((yearlyRate * daysDifference) / 365);
    }
}
