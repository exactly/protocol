// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./interfaces/IInterestRateModel.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/TSUtils.sol";
import "./utils/Errors.sol";
import "./utils/DecimalMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "hardhat/console.sol";

contract InterestRateModel is IInterestRateModel, AccessControl {
    using PoolLib for PoolLib.MaturityPool;

    // Parameters to the system, expressed with 1e18 decimals
    uint256 public marginRate;
    uint256 public mpSlopeRate;
    uint256 public spSlopeRate;
    uint256 public override baseRate;

    using DecimalMath for uint256;

    constructor(
        uint256 _marginRate,
        uint256 _mpSlopeRate,
        uint256 _spSlopeRate,
        uint256 _baseRate
    ) {
        marginRate = _marginRate;
        mpSlopeRate = _mpSlopeRate;
        spSlopeRate = _spSlopeRate;
        baseRate = _baseRate;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Function to update this model's parameters (TEAM_ONLY)
     * @param _marginRate spread between borrowing and lending
     * @param _mpSlopeRate slope to alter the utilization rate
     * @param _spSlopeRate slope to alter the utilization rate
     */
    function setParameters(
        uint256 _marginRate,
        uint256 _mpSlopeRate,
        uint256 _spSlopeRate,
        uint256 _baseRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        marginRate = _marginRate;
        mpSlopeRate = _mpSlopeRate;
        spSlopeRate = _spSlopeRate;
        baseRate = _baseRate;
    }

    /**
     * @dev Get current rate for borrow a certain amount in a certain maturity
     *      with supply/demand values in the maturity pool and supply demand values
     *      in the smart pool
     * @param maturityDate maturity date for calculating days left to maturity
     * @param maturityPool supply/demand values for the maturity pool
     * @param smartPool supply/demand values for the smartPool
     * @param newDebt checks if the maturity pool borrows money from the smart pool in this borrow
     */
    function getRateToBorrow(
        uint256 maturityDate,
        PoolLib.MaturityPool memory maturityPool,
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
                : baseRate +
                    (mpSlopeRate * maturityPool.borrowed) /
                    maturityPool.supplied;
        } else {
            yearlyRate = Math.max(
                smartPool.supplied == 0
                    ? 0
                    : (spSlopeRate * smartPool.borrowed) / smartPool.supplied,
                maturityPool.supplied == 0
                    ? 0
                    : baseRate +
                        (mpSlopeRate * maturityPool.borrowed) /
                        maturityPool.supplied
            );
        }

        return ((yearlyRate * daysDifference) / 365);
    }

    /**
     * @dev Get current rate for supplying a certain amount in a certain maturity
     *      with supply/demand values in the maturity pool and supply demand values
     *      in the smart pool
     * @param maturityDate maturity date for calculating days left to maturity
     * @param maturityPool supply/demand values for the maturity pool
     */
    function getRateToSupply(
        uint256 maturityDate,
        PoolLib.MaturityPool memory maturityPool
    ) external view override returns (uint256) {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }

        uint256 maturityPoolYearlyRate = maturityPool.supplied == 0
            ? 0
            : baseRate +
                ((mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied);

        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;

        return (maturityPoolYearlyRate * daysDifference) / (365);
    }
}
