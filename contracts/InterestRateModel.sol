// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "./interfaces/IInterestRateModel.sol";
import "./utils/Errors.sol";
import "./utils/DecimalMath.sol";

contract InterestRateModel is IInterestRateModel, AccessControl {
    using PoolLib for PoolLib.MaturityPool;
    using DecimalMath for uint256;
    uint256 private constant YEAR = 365 days;

    // Parameters to the system, expressed with 1e18 decimals
    uint256 public curveParameterA;
    int256 public curveParameterB;
    uint256 public maxUtilizationRate;
    uint256 public spFeeRate;
    uint256 public override penaltyRate;

    constructor(
        uint256 _curveParameterA,
        int256 _curveParameterB,
        uint256 _maxUtilizationRate,
        uint256 _penaltyRate,
        uint256 _spFeeRate
    ) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        setParameters(
            _curveParameterA,
            _curveParameterB,
            _maxUtilizationRate,
            _penaltyRate,
            _spFeeRate
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
            earningsShare = ((Math.min(amount, suppliedSP) *
                unassignedEarnings) / suppliedSP);
            earningsShareSP = earningsShare.mul_(spFeeRate);
            earningsShare -= earningsShareSP;
        }
    }

    /**
     * @dev Function to update this model's parameters (DEFAULT_ADMIN_ROLE)
     * @param _curveParameterA curve parameter
     * @param _curveParameterB curve parameter
     * @param _maxUtilizationRate % of MP supp
     * @param _penaltyRate by-second rate charged on late repays, with 18 decimals
     * @param _spFeeRate rate charged to the mp depositors to be accrued by the sp borrowers
     */
    function setParameters(
        uint256 _curveParameterA,
        int256 _curveParameterB,
        uint256 _maxUtilizationRate,
        uint256 _penaltyRate,
        uint256 _spFeeRate
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        curveParameterA = _curveParameterA;
        curveParameterB = _curveParameterB;
        maxUtilizationRate = _maxUtilizationRate;
        penaltyRate = _penaltyRate;
        spFeeRate = _spFeeRate;
        // we call the getRateToBorrow function with an utilization rate of
        // zero to force it to revert in the tx that sets it, and not be able
        // to set an invalid curve (such as one yielding a negative interest
        // rate). Doing it works because it's a monotonously increasing function.
        getRateToBorrow(block.timestamp + 1, block.timestamp, 0, 100, 100);
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
     * @return rate to be applied to the amount to calculate the fee that the borrower will
     *         have to pay
     */
    function getRateToBorrow(
        uint256 maturityDate,
        uint256 currentDate,
        uint256 borrowedMP,
        uint256 suppliedMP,
        uint256 borrowableFromSP
    ) public view override returns (uint256) {
        if (currentDate >= maturityDate) {
            revert GenericError(ErrorCode.INVALID_TIME_DIFFERENCE);
        }
        uint256 supplied = Math.max(borrowableFromSP, suppliedMP);
        if (supplied == 0) {
            revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
        }
        uint256 utilizationRate = borrowedMP.div_(supplied);
        if (
            utilizationRate >= maxUtilizationRate ||
            borrowedMP > suppliedMP + borrowableFromSP
        ) {
            revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
        }
        int256 rate = int256(
            curveParameterA.div_(maxUtilizationRate - utilizationRate)
        ) + curveParameterB;
        // this curve _could_ go below zero if the parameters are set wrong.
        assert(rate > 0);
        return (uint256(rate) * (maturityDate - currentDate)) / YEAR;
    }
}
