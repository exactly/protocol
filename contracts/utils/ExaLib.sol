// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "../interfaces/IExafin.sol";
import "../interfaces/IEToken.sol";
import "../utils/DecimalMath.sol";
import "../utils/MarketsLib.sol";
import "../utils/Errors.sol";
import "../ExaToken.sol";

struct MarketRewardsState {
    uint224 index;
    uint32 block;
}

library ExaLib {
    using DecimalMath for uint256;
    using DecimalMath for Double;
    using SafeCast for uint256;

    event DistributedSupplierExa(
        address indexed exafin,
        address indexed supplier,
        uint supplierDelta,
        uint exaSupplyIndex
    );
    event DistributedBorrowerExa(
        address indexed exafin,
        address indexed borrower,
        uint borrowerDelta,
        uint exaBorrowIndex
    );
    event DistributedSmartPoolExa(
        address indexed exafin,
        address indexed supplier,
        uint smartSupplierDelta,
        uint smartPoolIndex
    );

    // Double precision
    uint224 public constant EXA_INITIAL_INDEX = 1e36;

    struct ExaState {
        uint256 exaSpeed;
        MarketRewardsState exaSupplyState;
        MarketRewardsState exaBorrowState;
        MarketRewardsState exaSmartState;
        mapping(address => uint256) exaSupplierIndex;
        mapping(address => uint256) exaBorrowerIndex;
        mapping(address => uint256) exaSmartSupplierIndex;
    }

    struct RewardsState {
        address exaToken;
        mapping(address => ExaLib.ExaState) exaState;
        mapping(address => uint) exaAccruedUser;
    }

    /**
     * @notice Accrue EXA to the market by updating the smart index
     * @param exafinAddress The address of the smart pool
     * @param blockNumber current block number (injected for testing purpuses)
     * @param exafinAddress The market whose supply index to update
     */
    function updateExaSmartPoolIndex(
        RewardsState storage exafinState,
        uint blockNumber,
        address exafinAddress
    ) external {
        _updateExaSmartPoolIndex(exafinState, blockNumber, exafinAddress);
    }

    function _updateExaSmartPoolIndex(
        RewardsState storage exafinState,
        uint blockNumber,
        address exafinAddress
    ) internal {
        ExaState storage exaState = exafinState.exaState[exafinAddress];
        MarketRewardsState storage smartState = exaState.exaSmartState;
        uint supplySpeed = exaState.exaSpeed;
        uint deltaBlocks = (blockNumber - uint(smartState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 smartTokens = IExafin(exafinAddress).eToken().totalSupply();
            uint256 exaAccruedDelta = deltaBlocks * supplySpeed;
            Double memory ratio = smartTokens > 0 ? exaAccruedDelta.fraction(smartTokens) : Double({value: 0});
            Double memory index = Double({value: smartState.index}).add_(ratio);
            exaState.exaSmartState = MarketRewardsState({
                index: index.value.toUint224(),
                block: blockNumber.toUint32()
            });
        } else if (deltaBlocks > 0) {
            smartState.block = blockNumber.toUint32();
        }
    }

    /**
     * @notice Accrue EXA to the market by updating the supply index
     * @param exafinAddress The market whose supply index to update
     * @param blockNumber current block number (injected for testing purpuses)
     * @param exafinAddress The market whose supply index to update
     */
    function updateExaSupplyIndex(
        RewardsState storage exafinState,
        uint blockNumber,
        address exafinAddress
    ) external {
        _updateExaSupplyIndex(exafinState, blockNumber, exafinAddress);
    }

    function _updateExaSupplyIndex(
        RewardsState storage exafinState,
        uint blockNumber,
        address exafinAddress
    ) internal {
        ExaState storage exaState = exafinState.exaState[exafinAddress];
        MarketRewardsState storage supplyState = exaState.exaSupplyState;
        uint supplySpeed = exaState.exaSpeed;
        uint deltaBlocks = (blockNumber - uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 supplyTokens = IExafin(exafinAddress).totalDeposits();
            uint256 exaAccruedDelta = deltaBlocks * supplySpeed;
            Double memory ratio = supplyTokens > 0 ? exaAccruedDelta.fraction(supplyTokens) : Double({value: 0});
            Double memory index = Double({value: supplyState.index}).add_(ratio);
            exaState.exaSupplyState = MarketRewardsState({
                index: index.value.toUint224(),
                block: blockNumber.toUint32()
            });
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber.toUint32();
        }
    }

    /**
     * @notice Accrue EXA to the market by updating the supply index
     * @param exafinState RewardsState storage in Auditor
     * @param blockNumber current block number (injected for testing purpuses)
     * @param exafinAddress The market whose supply index to update
     */
    function updateExaBorrowIndex(
        RewardsState storage exafinState,
        uint blockNumber,
        address exafinAddress
    ) external {
        _updateExaBorrowIndex(exafinState, blockNumber, exafinAddress);
    }

    function _updateExaBorrowIndex(
        RewardsState storage exafinState,
        uint blockNumber,
        address exafinAddress
    ) internal {
        ExaState storage exaState = exafinState.exaState[exafinAddress];
        MarketRewardsState storage borrowState = exaState.exaBorrowState;
        uint borrowSpeed = exaState.exaSpeed;
        uint deltaBlocks = blockNumber - uint(borrowState.block);
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = IExafin(exafinAddress).totalBorrows();
            uint256 exaAccruedDelta = deltaBlocks * borrowSpeed;

            Double memory ratio = borrowAmount > 0 ? exaAccruedDelta.fraction(borrowAmount) : Double({value: 0});
            Double memory index = Double({value: borrowState.index}).add_(ratio);

            exaState.exaBorrowState = MarketRewardsState({
                index: index.value.toUint224(),
                block: blockNumber.toUint32()
            });
        } else if (deltaBlocks > 0) {
            borrowState.block = blockNumber.toUint32();
        }
    }

    /**
     * @notice Calculate EXA accrued by a supplier and possibly transfer it to them
     * @param exafinState RewardsState storage in Auditor
     * @param exafinAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function distributeSmartPoolExa(
        RewardsState storage exafinState, 
        address exafinAddress,
        address supplier
    ) external {
        _distributeSmartPoolExa(exafinState, exafinAddress, supplier);
    }

    /**
     * @notice INTERNAL Calculate EXA accrued by a supplier and possibly transfer it to them
     * @param exafinState RewardsState storage in Auditor
     * @param exafinAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function _distributeSmartPoolExa(
        RewardsState storage exafinState,
        address exafinAddress,
        address supplier
    ) internal {
        ExaState storage exaState = exafinState.exaState[exafinAddress];
        MarketRewardsState storage smartState = exaState.exaSmartState;
        Double memory smartPoolIndex = Double({value: smartState.index});
        Double memory smartSupplierIndex = Double({value: exaState.exaSmartSupplierIndex[supplier]});
        exaState.exaSmartSupplierIndex[supplier] = smartPoolIndex.value;

        if (smartSupplierIndex.value == 0 && smartPoolIndex.value > 0) {
            smartSupplierIndex.value = EXA_INITIAL_INDEX;
        }

        Double memory deltaIndex = smartPoolIndex.sub_(smartSupplierIndex);

        uint smartSupplierTokens = IExafin(exafinAddress).eToken().balanceOf(supplier);
        uint smartSupplierDelta = smartSupplierTokens.mul_(deltaIndex);
        uint smartSupplierAccrued = exafinState.exaAccruedUser[supplier] + smartSupplierDelta;
        exafinState.exaAccruedUser[supplier] = smartSupplierAccrued;
        emit DistributedSmartPoolExa(exafinAddress, supplier, smartSupplierDelta, smartPoolIndex.value);
    }

    /**
     * @notice Calculate EXA accrued by a supplier and possibly transfer it to them
     * @param exafinState RewardsState storage in Auditor
     * @param exafinAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function distributeSupplierExa(
        RewardsState storage exafinState, 
        address exafinAddress,
        address supplier
    ) external {
        _distributeSupplierExa(exafinState, exafinAddress, supplier);
    }

    /**
     * @notice INTERNAL Calculate EXA accrued by a supplier and possibly transfer it to them
     * @param exafinState RewardsState storage in Auditor
     * @param exafinAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function _distributeSupplierExa(
        RewardsState storage exafinState,
        address exafinAddress,
        address supplier
    ) internal {
        ExaState storage exaState = exafinState.exaState[exafinAddress];
        MarketRewardsState storage supplyState = exaState.exaSupplyState;
        Double memory supplyIndex = Double({value: supplyState.index});
        Double memory supplierIndex = Double({value: exaState.exaSupplierIndex[supplier]});
        exaState.exaSupplierIndex[supplier] = supplyIndex.value;

        if (supplierIndex.value == 0 && supplyIndex.value > 0) {
            supplierIndex.value = EXA_INITIAL_INDEX;
        }

        Double memory deltaIndex = supplyIndex.sub_(supplierIndex);

        uint supplierTokens = IExafin(exafinAddress).totalDepositsUser(supplier);
        uint supplierDelta = supplierTokens.mul_(deltaIndex);
        uint supplierAccrued = exafinState.exaAccruedUser[supplier] + supplierDelta;
        exafinState.exaAccruedUser[supplier] = supplierAccrued;
        emit DistributedSupplierExa(exafinAddress, supplier, supplierDelta, supplyIndex.value);
    }


    /**
     * @notice Calculate EXA accrued by a borrower
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param exafinAddress The market address in which the borrower is interacting
     * @param borrower The address of the borrower to distribute EXA to
     */
    function distributeBorrowerExa(
        RewardsState storage exafinState,
        address exafinAddress,
        address borrower
    ) external {
        _distributeBorrowerExa(exafinState, exafinAddress, borrower);
    }

    /**
     * @notice Calculate EXA accrued by a borrower
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param exafinAddress The market address in which the borrower is interacting
     * @param borrower The address of the borrower to distribute EXA to
     */
    function _distributeBorrowerExa(
        RewardsState storage exafinState,
        address exafinAddress,
        address borrower
    ) internal {
        ExaState storage exaState = exafinState.exaState[exafinAddress];
        MarketRewardsState storage borrowState = exaState.exaBorrowState;

        Double memory borrowIndex = Double({value: borrowState.index});
        Double memory borrowerIndex = Double({value: exaState.exaBorrowerIndex[borrower]});
        exaState.exaBorrowerIndex[borrower] = borrowIndex.value;

        if (borrowerIndex.value > 0) {
            Double memory deltaIndex = borrowIndex.sub_(borrowerIndex);
            uint borrowerAmount = IExafin(exafinAddress).totalBorrowsUser(borrower);
            uint borrowerDelta = borrowerAmount.mul_(deltaIndex);
            uint borrowerAccrued = exafinState.exaAccruedUser[borrower] + borrowerDelta;
            exafinState.exaAccruedUser[borrower] = borrowerAccrued;
            emit DistributedBorrowerExa(exafinAddress, borrower, borrowerDelta, borrowIndex.value);
        }
    }

    /**
     * @notice Claim all EXA accrued by the holders
     * @param exafinState RewardsState storage in Auditor
     * @param blockNumber current block number (injected for testing purpuses)
     * @param markets Valid markets in Auditor
     * @param holders The addresses to claim EXA for
     * @param exafinAddresses The list of markets to claim EXA in
     * @param borrowers Whether or not to claim EXA earned by borrowing
     * @param suppliers Whether or not to claim EXA earned by supplying
     */
    function claimExa(
        RewardsState storage exafinState,
        uint blockNumber,
        mapping(address => MarketsLib.Market) storage markets,
        address[] memory holders,
        address[] memory exafinAddresses,
        bool borrowers,
        bool suppliers,
        bool smartSuppliers
    ) external {

        for (uint i = 0; i < exafinAddresses.length; i++) {
            address exafin = exafinAddresses[i];
            MarketsLib.Market storage market = markets[exafin];

            if (!market.isListed) {
                revert GenericError(ErrorCode.MARKET_NOT_LISTED);
            }

            if (borrowers == true) {
                _updateExaBorrowIndex(exafinState, blockNumber, exafin);
                for (uint j = 0; j < holders.length; j++) {
                    _distributeBorrowerExa(exafinState, exafin, holders[j]);
                    exafinState.exaAccruedUser[holders[j]] = _grantExa(exafinState, holders[j], exafinState.exaAccruedUser[holders[j]]);
                }
            }
            if (suppliers == true) {
                _updateExaSupplyIndex(exafinState, blockNumber, exafin);
                for (uint j = 0; j < holders.length; j++) {
                    _distributeSupplierExa(exafinState, exafin, holders[j]);
                    exafinState.exaAccruedUser[holders[j]] = _grantExa(exafinState, holders[j], exafinState.exaAccruedUser[holders[j]]);
                }
            }

            if (smartSuppliers == true) {
                _updateExaSmartPoolIndex(exafinState, blockNumber, exafin);
                for (uint j = 0; j < holders.length; j++) {
                    _distributeSmartPoolExa(exafinState, exafin, holders[j]);
                    exafinState.exaAccruedUser[holders[j]] = _grantExa(exafinState, holders[j], exafinState.exaAccruedUser[holders[j]]);
                }
            }

        }
    }

    /**
     * @notice Transfer EXA to the user
     * @param exafinState RewardsState storage in Auditor
     * @param user The address of the user to transfer EXA to
     * @param amount The amount of EXA to (possibly) transfer
     * @return The amount of EXA which was NOT transferred to the user
     */
    function grantExa(
        RewardsState storage exafinState,
        address user,
        uint amount
    ) external returns (uint) {
        return _grantExa(exafinState, user, amount);
    }

    /**
     * @notice Transfer EXA to the user
     * @param exafinState RewardsState storage in Auditor
     * @param user The address of the user to transfer EXA to
     * @param amount The amount of EXA to (possibly) transfer
     * @return The amount of EXA which was NOT transferred to the user
     */
    function _grantExa(
        RewardsState storage exafinState,
        address user,
        uint amount
    ) internal returns (uint) {
        ExaToken exa = ExaToken(exafinState.exaToken);
        uint exaBalance = exa.balanceOf(address(this));
        if (amount > 0 && amount <= exaBalance) {
            exa.transfer(user, amount);
            return 0;
        }
        return amount;
    }

    /**
     * @notice Set EXA speed for a single market
     * @param exafinState RewardsState storage in Auditor
     * @param blockNumber current block number (injected for testing purpuses)
     * @param exafinAddress The market whose EXA speed to update
     * @param exaSpeed New EXA speed for market
     */
    function setExaSpeed(
        RewardsState storage exafinState,
        uint blockNumber,
        address exafinAddress,
        uint256 exaSpeed
    ) external returns (bool) {
        ExaState storage state = exafinState.exaState[exafinAddress];
        uint currentExaSpeed = state.exaSpeed;
        if (currentExaSpeed != 0) {
            _updateExaSupplyIndex(exafinState, blockNumber, exafinAddress);
            _updateExaBorrowIndex(exafinState, blockNumber, exafinAddress);
            _updateExaSmartPoolIndex(exafinState, blockNumber, exafinAddress);
        } else if (exaSpeed != 0) {
            // what happens @ compound.finance if someone doesn't set the exaSpeed
            // but supply/borrow first? in that case, block number will be updated
            // hence the market can never be initialized with EXA_INITIAL_INDEX
            // if (state.exaSupplyState.index == 0 && state.exaSupplyState.block == 0) {
            if (state.exaSupplyState.index == 0) {
                state.exaSupplyState = MarketRewardsState({
                    index: EXA_INITIAL_INDEX,
                    block: blockNumber.toUint32()
                });
            }

            if (state.exaBorrowState.index == 0) {
                state.exaBorrowState = MarketRewardsState({
                    index: EXA_INITIAL_INDEX,
                    block: blockNumber.toUint32()
                });
            }

            if (state.exaSmartState.index == 0) {
                state.exaSmartState = MarketRewardsState({
                    index: EXA_INITIAL_INDEX,
                    block: blockNumber.toUint32()
                });
            }
        }

        if (currentExaSpeed != exaSpeed) {
            state.exaSpeed = exaSpeed;
            return true;
        }

        return false;
    }

}
