// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./interfaces/IInterestRateModel.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/Errors.sol";
import "./utils/DecimalMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract InterestRateModel is IInterestRateModel, AccessControl {
    using PoolLib for PoolLib.MaturityPool;
    using DecimalMath for uint256;
    uint256 private constant YEAR = 365 days;

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
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        setParameters(
            _curveParameterA,
            _curveParameterB,
            _maxUtilizationRate,
            _penaltyRate
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
        uint256 amount,
        uint256 mpDepositsWeighter
    ) external pure override returns (uint256 earningsShare) {
        amount = amount.mul_(mpDepositsWeighter);
        uint256 supply = suppliedSP + amount;
        earningsShare = (amount * unassignedEarnings) / supply;
    }

    /**
     * @dev Function to update this model's parameters (DEFAULT_ADMIN_ROLE)
     * @param _curveParameterA curve parameter
     * @param _curveParameterB curve parameter
     * @param _maxUtilizationRate % of MP supp
     * @param _penaltyRate by-second rate charged on late repays, with 18 decimals
     */
    function setParameters(
        uint256 _curveParameterA,
        int256 _curveParameterB,
        uint256 _maxUtilizationRate,
        uint256 _penaltyRate
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        curveParameterA = _curveParameterA;
        curveParameterB = _curveParameterB;
        maxUtilizationRate = _maxUtilizationRate;
        penaltyRate = _penaltyRate;
        // we call the getRateToBorrow function with an utilization rate of
        // zero to force it to revert in the tx that sets it, and not be able
        // to set an invalid curve (such as one yielding a negative interest
        // rate). Doing it works because it's a monotonously increasing function.
        getRateToBorrow(block.timestamp + 1, block.timestamp, 0, 100, 100);
    }

    /**
     * @notice Get current rate for borrow a certain amount in a certain maturity
     *      with supply/demand values in the maturity pool and supply demand values
     *      in the smart pool
     * @dev liquidity limits aren't checked, that's the responsibility of pool.takeMoney.
     * @param maturityDate maturity date for calculating days left to maturity
     * @param currentDate the curent block timestamp. Recieved from caller for easier testing
     * @param borrowedMP total borrowed from this maturity
     * @param suppliedMP total supplied to this maturity
     * @param smartPoolLiquidityShare 'fair' share of the smart pool that this maturity can borrow
     * @return rate to be applied to the amount to calculate the fee that the borrower will
     *         have to pay
     */
    function getRateToBorrow(
        uint256 maturityDate,
        uint256 currentDate,
        uint256 borrowedMP,
        uint256 suppliedMP,
        uint256 smartPoolLiquidityShare
    ) public view override returns (uint256) {
        if (currentDate >= maturityDate) {
            revert GenericError(ErrorCode.INVALID_TIME_DIFFERENCE);
        }
        uint256 supplied = Math.max(smartPoolLiquidityShare, suppliedMP);
        if (supplied == 0) {
            revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
        }
        uint256 utilizationRate = borrowedMP.div_(supplied);
        if (utilizationRate >= maxUtilizationRate) {
            revert GenericError(ErrorCode.EXCEEDED_MAX_UTILIZATION_RATE);
        }
        int256 rate = int256(
            curveParameterA.div_(maxUtilizationRate - utilizationRate)
        ) + curveParameterB;
        // this curve _could_ go below zero if the parameters are set wrong.
        assert(rate > 0);
        return (uint256(rate) * (maturityDate - currentDate)) / YEAR;
    }
}
