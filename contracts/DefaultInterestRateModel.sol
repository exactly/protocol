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
    uint256 public spHighURSlope;
    uint256 public breakRate;

    using DecimalMath for uint256;

    constructor(
        uint256 _marginRate,
        uint256 _mpSlopeRate,
        uint256 _spSlopeRate,
        uint256 _spHighURSlope,
        uint256 _breakRate
    ) {
        marginRate = _marginRate;
        mpSlopeRate = _mpSlopeRate;
        spSlopeRate = _spSlopeRate;
        spHighURSlope = _spHighURSlope;
        breakRate = _breakRate;

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
        uint256 _spSlopeRate,
        uint256 _spHighURSlope
    ) external onlyRole(TEAM_ROLE) {
        marginRate = _marginRate;
        mpSlopeRate = _mpSlopeRate;
        spSlopeRate = _spSlopeRate;
        spHighURSlope = _spHighURSlope;
    }

    /**
        @dev Get current rate for borrow a certain amount in a certain maturity
             with supply/demand values in the maturity pool and supply demand values
             in the smart pool
        @param maturityDate maturity date for calculating days left to maturity
        @param maturityPool supply/demand values for the maturity pool
        @param smartPool supply/demand values for the smartPool
        @param newDebt checks if the maturity pool borrows money from the smart pool in this borrow
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

        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;
        uint256 yearlyRate;

        if (!newDebt) {
            yearlyRate = maturityPool.supplied == 0
                ? 0
                : (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;
        } else {
            uint256 smartPoolUtilizationRate = smartPool.supplied == 0 ? 0 : smartPool.borrowed.div_(smartPool.supplied);
            uint256 spCurrentSlopeRate = smartPoolUtilizationRate >= breakRate ? spHighURSlope : spSlopeRate;

            yearlyRate = Math.max(
                smartPool.supplied == 0
                    ? 0
                    : (spCurrentSlopeRate * smartPool.borrowed) / smartPool.supplied,
                maturityPool.supplied == 0
                    ? 0
                    : (mpSlopeRate * maturityPool.borrowed) /
                        maturityPool.supplied
            );
        }

        return ((yearlyRate * daysDifference) / 365);
    }

    /**
        @dev Get current rate for supplying a certain amount in a certain maturity
             with supply/demand values in the maturity pool and supply demand values
             in the smart pool
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

        uint256 smartPoolUtilizationRate = smartPool.supplied == 0 ? 0 : smartPool.borrowed.div_(smartPool.supplied);
        bool isHighURSlope = smartPoolUtilizationRate >= breakRate ? true : false;

        uint256 yearlyRate;
        uint256 maturityPoolYearlyRate = maturityPool.supplied == 0
            ? 0
            : (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;
        uint256 smartPoolYearlyRate = smartPool.supplied == 0
            ? 0
            : isHighURSlope ? spSlopeRate : ((spSlopeRate * smartPool.borrowed) /
                (smartPool.supplied + amount));

        if (
            maturityPoolYearlyRate != 0 &&
            maturityPool.supplied - maturityPool.borrowed != 0
        ) {
            yearlyRate = maturityPoolYearlyRate;
        }

        if (
            (smartPoolYearlyRate != 0 && maturityPoolYearlyRate == 0) ||
            maturityPool.supplied - maturityPool.borrowed == 0
        ) {
            yearlyRate = smartPoolYearlyRate;
        }

        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;

        return ((yearlyRate * daysDifference) / 365);
    }
}
