// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "./interfaces/IInterestRateModel.sol";
import "./utils/Errors.sol";
import "./utils/PoolLib.sol";

contract InterestRateModel is IInterestRateModel, AccessControl {
    using PoolLib for PoolLib.MaturityPool;
    using FixedPointMathLib for uint256;
    uint256 private constant YEAR = 365 days;

    // Parameters to the system, expressed with 1e18 decimals
    uint256 public curveParameterA;
    int256 public curveParameterB;
    uint256 public maxUtilizationRate;
    uint256 public override penaltyRate;
    uint256 public spFeeRate;

    event ParametersUpdated(
        uint256 a,
        int256 b,
        uint256 maxUtilizationRate,
        uint256 penaltyRate,
        uint256 spFeeRate
    );

    constructor(
        uint256 _curveParameterA,
        int256 _curveParameterB,
        uint256 _maxUtilizationRate,
        uint256 _penaltyRate,
        uint256 _spFeeRate
    ) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        curveParameterA = _curveParameterA;
        curveParameterB = _curveParameterB;
        maxUtilizationRate = _maxUtilizationRate;
        penaltyRate = _penaltyRate;
        spFeeRate = _spFeeRate;
    }

    /**
     * @dev Sets the rate charged to the mp depositors to be accrued by the sp borrowers
     * @param _spFeeRate percentage amount represented with 1e18 decimals
     */
    function setSPFeeRate(uint256 _spFeeRate)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        spFeeRate = _spFeeRate;

        emit ParametersUpdated(
            curveParameterA,
            curveParameterB,
            maxUtilizationRate,
            penaltyRate,
            _spFeeRate
        );
    }

    /// @notice sets the penalty rate per second
    /// @param penaltyRate_ percentage represented with 18 decimals
    function setPenaltyRate(uint256 penaltyRate_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        penaltyRate = penaltyRate_;

        emit ParametersUpdated(
            curveParameterA,
            curveParameterB,
            maxUtilizationRate,
            penaltyRate_,
            spFeeRate
        );
    }

    /// @notice gets this model's parameters
    /// @return parameters (curveA, curveB, maxUtilizationRate, penaltyRate, spFeeRate)
    function getParameters()
        external
        view
        returns (
            uint256,
            int256,
            uint256,
            uint256,
            uint256
        )
    {
        return (
            curveParameterA,
            curveParameterB,
            maxUtilizationRate,
            penaltyRate,
            spFeeRate
        );
    }

    /**
     * @dev Calculate the amount of revenue sharing between the smart pool and the new MP depositor.
     * @param suppliedSP amount of money currently being supplied in the maturity pool
     * @param unassignedEarnings earnings not yet accrued to the SP that should be shared with the
     *        current depositor
     * @param amount amount being provided by the MP depositor
     * @return earningsShare : yield to be given to the MP depositor
     */
    function getYieldForDeposit(
        uint256 suppliedSP,
        uint256 unassignedEarnings,
        uint256 amount
    )
        external
        view
        override
        returns (uint256 earningsShare, uint256 earningsShareSP)
    {
        if (suppliedSP != 0) {
            // User can't make more fees after the total borrowed amount
            earningsShare = unassignedEarnings.fmul(
                Math.min(amount, suppliedSP),
                suppliedSP
            );
            earningsShareSP = earningsShare.fmul(spFeeRate, 1e18);
            earningsShare -= earningsShareSP;
        }
    }

    /// @dev updates this model's curve parameters
    /// @param curveA curve parameter
    /// @param curveB curve parameter
    /// @param targetUtilizationRate % of MP supp
    function setCurveParameters(
        uint256 curveA,
        int256 curveB,
        uint256 targetUtilizationRate
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        curveParameterA = curveA;
        curveParameterB = curveB;
        maxUtilizationRate = targetUtilizationRate;
        // we call the getPointInCurve function with an utilization rate of
        // zero to force it to revert in the tx that sets it, and not be able
        // to set an invalid curve (such as one yielding a negative interest
        // rate). Doing it works because it's a monotonously increasing function.
        getPointInCurve(0);

        emit ParametersUpdated(
            curveA,
            curveB,
            targetUtilizationRate,
            penaltyRate,
            spFeeRate
        );
    }

    /**
     * @notice Get fee to borrow a certain amount in a certain maturity
     *      with supply/demand values in the maturity pool and supply/demand values
     *      in the smart pool
     * @dev liquidity limits aren't checked, that's the responsibility of pool.takeMoney.
     * @param maturityDate maturity date for calculating days left to maturity
     * @param currentDate the curent block timestamp. Recieved from caller for easier testing
     * @param borrowedMP total borrowed from this maturity
     * @param suppliedMP total supplied to this maturity
     * @param smartPoolLiquidityShare 'fair' share of the smart pool that this maturity can borrow
     * @return fee the borrower will have to pay
     */
    function getFeeToBorrow(
        uint256 maturityDate,
        uint256 currentDate,
        uint256 borrowedMP,
        uint256 suppliedMP,
        uint256 smartPoolLiquidityShare
    ) public view override returns (uint256) {
        if (currentDate >= maturityDate) {
            revert GenericError(ErrorCode.INVALID_TIME_DIFFERENCE);
        }
        uint256 supplied = smartPoolLiquidityShare + suppliedMP;
        if (supplied == 0) {
            revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
        }
        uint256 rate = getPointInCurve(borrowedMP.fdiv(supplied, 1e18));
        return (rate * (maturityDate - currentDate)) / YEAR;
    }

    function getPointInCurve(uint256 utilizationRate)
        internal
        view
        returns (uint256)
    {
        if (utilizationRate >= maxUtilizationRate) {
            revert GenericError(ErrorCode.EXCEEDED_MAX_UTILIZATION_RATE);
        }
        int256 rate = int256(
            curveParameterA.fdiv(maxUtilizationRate - utilizationRate, 1e18)
        ) + curveParameterB;
        // this curve _could_ go below zero if the parameters are set wrong.
        assert(rate >= 0);
        return uint256(rate);
    }

    function trapezoidIntegrator(uint256 ut, uint256 ut1)
        internal
        view
        returns (uint256)
    {
        uint256 denominator = ut1 - ut;
        uint256 delta = denominator / 4;
        uint256 numerator = getPointInCurve(ut) +
            2 *
            getPointInCurve(ut + delta) +
            2 *
            getPointInCurve(ut + 2 * delta) +
            2 *
            getPointInCurve(ut + 3 * delta) +
            getPointInCurve(ut1);
        return ((delta / 2) * numerator) / denominator;
    }

    function midpointIntegrator(uint256 ut, uint256 ut1)
        internal
        view
        returns (uint256)
    {
        uint256 denominator = ut1 - ut;
        uint256 delta = denominator / 4;
        uint256 numerator = getPointInCurve(ut + delta.fmul(0.5 ether, 1 ether)) +
            getPointInCurve(ut + delta.fmul(1.5 ether, 1 ether)) +
            getPointInCurve(ut + delta.fmul(2.5 ether, 1 ether)) +
            getPointInCurve(ut + delta.fmul(3.5 ether, 1 ether));
        return (delta * numerator) / denominator;
    }
}
