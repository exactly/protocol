// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./interfaces/IInterestRateModel.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/Errors.sol";
import "./utils/DecimalMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

//solhint-ignore no-empty-blocks

contract InterestRateModel is IInterestRateModel, AccessControl {
    using PoolLib for PoolLib.MaturityPool;
    using DecimalMath for uint256;

    // Parameters to the system, expressed with 1e18 decimals
    uint256 public curveParameterA;
    int256 public curveParameterB;
    uint256 public maxUtilizationRate;
    uint256 public override penaltyRate;

    constructor(
        uint256 _curveParameterA,
        int256 _curveParameterB,
        uint256 _maxUtilizationRate,
        uint256 _penaltyRate
    ) {
        curveParameterA = _curveParameterA;
        curveParameterB = _curveParameterB;
        maxUtilizationRate = _maxUtilizationRate;
        penaltyRate = _penaltyRate;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Function to update this model's parameters (DEFAULT_ADMIN_ROLE)
     * @param _curveParameterA curve parameter
     * @param _curveParameterB curve parameter
     * @param _maxUtilizationRate % of MP supp
     * @param _penaltyRate daily rate charged on late repays. 18 decimals
     */
    function setParameters(
        uint256 _curveParameterA,
        int256 _curveParameterB,
        uint256 _maxUtilizationRate,
        uint256 _penaltyRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        curveParameterA = _curveParameterA;
        curveParameterB = _curveParameterB;
        maxUtilizationRate = _maxUtilizationRate;
        penaltyRate = _penaltyRate;
    }

    /**
     * @dev Get current rate for borrow a certain amount in a certain maturity
     *      with supply/demand values in the maturity pool and supply demand values
     *      in the smart pool
     * @param maturityDate maturity date for calculating days left to maturity
     * @param currentDate the curent block timestamp. Recieved from caller for easier testing
     * @param borrowedMP total borrowed from this maturity
     * @param suppliedMP total supplied to this maturity
     * @param borrowableFromSP max amount the smart pool is able to lend to this maturity
     */
    function getRateToBorrow(
        uint256 maturityDate,
        uint256 currentDate,
        uint256 borrowedMP,
        uint256 suppliedMP,
        uint256 borrowableFromSP
    ) external view override returns (uint256) {
        // FIXME: add a test where the liquidity from the MP is used
        uint256 supplied = borrowableFromSP;
        // this'll be in the tokens' decimals. very much not ideal.
        // FIXME: add a test with decimals other than 18 so this breaks
        uint256 utilizationRate = borrowedMP.div_(supplied);
        int256 rate = int256(
            curveParameterA.div_(maxUtilizationRate - utilizationRate)
        ) + curveParameterB;
        // this curve _could_ go below zero if the parameters are set wrong.
        assert(rate > 0);
        return uint256(rate);
    }
}
