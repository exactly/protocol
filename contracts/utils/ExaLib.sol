// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "../interfaces/IFixedLender.sol";
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

    struct ExaState {
        uint256 exaSpeed;
        MarketRewardsState exaMPSupplyState;
        MarketRewardsState exaMPBorrowState;
        MarketRewardsState exaSPSupplyState;
        mapping(address => uint256) exaMPSupplierIndex;
        mapping(address => uint256) exaMPBorrowerIndex;
        mapping(address => uint256) exaSPSupplierIndex;
    }

    struct RewardsState {
        address exaToken;
        mapping(address => ExaLib.ExaState) exaState;
        mapping(address => uint) exaAccruedUser;
    }

    // Double precision
    uint224 public constant EXA_INITIAL_INDEX = 1e36;

    event DistributedMPSupplierExa(
        address indexed fixedLender,
        address indexed supplier,
        uint mpSupplierDelta,
        uint exaMPSupplyIndex
    );
    event DistributedMaturityBorrowerExa(
        address indexed fixedLender,
        address indexed borrower,
        uint borrowerDelta,
        uint exaBorrowIndex
    );
    event DistributedSmartSupplierExa(
        address indexed fixedLender,
        address indexed supplier,
        uint smartSupplierDelta,
        uint smartPoolIndex
    );

    /**
     * @notice Calculate EXA accrued by a smart pool supplier and possibly transfer them to him
     * @param fixedLenderState RewardsState storage in Auditor
     * @param fixedLenderAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function distributeSmartSupplierExa(
        RewardsState storage fixedLenderState, 
        address fixedLenderAddress,
        address supplier
    ) external {
        _distributeSmartSupplierExa(fixedLenderState, fixedLenderAddress, supplier);
    }

    /**
     * @notice Calculate EXA accrued by a maturity pool supplier and possibly transfer them to him
     * @param fixedLenderState RewardsState storage in Auditor
     * @param fixedLenderAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function distributeMaturitySupplierExa(
        RewardsState storage fixedLenderState, 
        address fixedLenderAddress,
        address supplier
    ) external {
        _distributeMaturitySupplierExa(fixedLenderState, fixedLenderAddress, supplier);
    }

    /**
     * @notice Calculate EXA accrued by a maturity pool borrower
     * @dev Borrowers will not begin to accrue until the first interaction with the protocol.
     * @param fixedLenderAddress The market address in which the borrower is interacting
     * @param borrower The address of the borrower to distribute EXA to
     */
    function distributeMaturityBorrowerExa(
        RewardsState storage fixedLenderState,
        address fixedLenderAddress,
        address borrower
    ) external {
        _distributeMaturityBorrowerExa(fixedLenderState, fixedLenderAddress, borrower);
    }

    /**
     * @notice Claim all EXA accrued by the holders
     * @param fixedLenderState RewardsState storage in Auditor
     * @param blockNumber current block number (injected for testing purpuses)
     * @param markets Valid markets in Auditor
     * @param holders The addresses to claim EXA for
     * @param fixedLenderAddresses The list of markets to claim EXA in
     * @param maturityBorrowers Whether or not to claim EXA earned by maturity pool borrowing
     * @param maturitySuppliers Whether or not to claim EXA earned by maturity pool supplying
     * @param smartSuppliers Whether or not to claim EXA earned by smart pool supplying
     */
    function claimExa(
        RewardsState storage fixedLenderState,
        uint blockNumber,
        mapping(address => MarketsLib.Market) storage markets,
        address[] memory holders,
        address[] memory fixedLenderAddresses,
        bool maturityBorrowers,
        bool maturitySuppliers,
        bool smartSuppliers
    ) external {
        for (uint i = 0; i < fixedLenderAddresses.length; i++) {
            address fixedLender = fixedLenderAddresses[i];
            MarketsLib.Market storage market = markets[fixedLender];

            if (!market.isListed) {
                revert GenericError(ErrorCode.MARKET_NOT_LISTED);
            }

            if (maturityBorrowers == true) {
                updateExaMaturityBorrowIndex(fixedLenderState, blockNumber, fixedLender);
                for (uint j = 0; j < holders.length; j++) {
                    _distributeMaturityBorrowerExa(fixedLenderState, fixedLender, holders[j]);
                    fixedLenderState.exaAccruedUser[holders[j]] = _grantExa(fixedLenderState, holders[j], fixedLenderState.exaAccruedUser[holders[j]]);
                }
            }
            if (maturitySuppliers == true) {
                updateExaMaturitySupplyIndex(fixedLenderState, blockNumber, fixedLender);
                for (uint j = 0; j < holders.length; j++) {
                    _distributeMaturitySupplierExa(fixedLenderState, fixedLender, holders[j]);
                    fixedLenderState.exaAccruedUser[holders[j]] = _grantExa(fixedLenderState, holders[j], fixedLenderState.exaAccruedUser[holders[j]]);
                }
            }

            if (smartSuppliers == true) {
                updateExaSmartSupplyIndex(fixedLenderState, blockNumber, fixedLender);
                for (uint j = 0; j < holders.length; j++) {
                    _distributeSmartSupplierExa(fixedLenderState, fixedLender, holders[j]);
                    fixedLenderState.exaAccruedUser[holders[j]] = _grantExa(fixedLenderState, holders[j], fixedLenderState.exaAccruedUser[holders[j]]);
                }
            }
        }
    }

    /**
     * @notice Transfer EXA to the user
     * @param fixedLenderState RewardsState storage in Auditor
     * @param user The address of the user to transfer EXA to
     * @param amount The amount of EXA to (possibly) transfer
     * @return The amount of EXA which was NOT transferred to the user
     */
    function grantExa(
        RewardsState storage fixedLenderState,
        address user,
        uint amount
    ) external returns (uint) {
        return _grantExa(fixedLenderState, user, amount);
    }

    /**
     * @notice Set EXA speed for a single market
     * @param fixedLenderState RewardsState storage in Auditor
     * @param blockNumber current block number (injected for testing purpuses)
     * @param fixedLenderAddress The market whose EXA speed to update
     * @param exaSpeed New EXA speed for market
     */
    function setExaSpeed(
        RewardsState storage fixedLenderState,
        uint blockNumber,
        address fixedLenderAddress,
        uint256 exaSpeed
    ) external returns (bool) {
        ExaState storage state = fixedLenderState.exaState[fixedLenderAddress];
        uint currentExaSpeed = state.exaSpeed;
        if (currentExaSpeed != 0) {
            updateExaMaturitySupplyIndex(fixedLenderState, blockNumber, fixedLenderAddress);
            updateExaMaturityBorrowIndex(fixedLenderState, blockNumber, fixedLenderAddress);
            updateExaSmartSupplyIndex(fixedLenderState, blockNumber, fixedLenderAddress);
        } else if (exaSpeed != 0) {
            // what happens @ compound.finance if someone doesn't set the exaSpeed
            // but supply/borrow first? in that case, block number will be updated
            // hence the market can never be initialized with EXA_INITIAL_INDEX
            // if (state.exaMPSupplyState.index == 0 && state.exaMPSupplyState.block == 0) {
            if (state.exaMPSupplyState.index == 0) {
                state.exaMPSupplyState = MarketRewardsState({
                    index: EXA_INITIAL_INDEX,
                    block: blockNumber.toUint32()
                });
            }

            if (state.exaMPBorrowState.index == 0) { 
                state.exaMPBorrowState = MarketRewardsState({
                    index: EXA_INITIAL_INDEX,
                    block: blockNumber.toUint32()
                });
            }

            if (state.exaSPSupplyState.index == 0) {
                state.exaSPSupplyState = MarketRewardsState({
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

    /**
     * @notice Accrue EXA to the market by updating the smart pool supply index
     * @param fixedLenderAddress The address of the smart pool
     * @param blockNumber current block number (injected for testing purpuses)
     * @param fixedLenderAddress The market whose supply index to update
     */
    function updateExaSmartSupplyIndex(
        RewardsState storage fixedLenderState,
        uint blockNumber,
        address fixedLenderAddress
    ) public {
        ExaState storage exaState = fixedLenderState.exaState[fixedLenderAddress];
        MarketRewardsState storage smartState = exaState.exaSPSupplyState;
        uint supplySpeed = exaState.exaSpeed;
        uint deltaBlocks = (blockNumber - uint(smartState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 smartTokens = IFixedLender(fixedLenderAddress).eToken().totalSupply();
            uint256 exaAccruedDelta = deltaBlocks * supplySpeed;
            Double memory ratio = smartTokens > 0 ? exaAccruedDelta.fraction(smartTokens) : Double({value: 0});
            Double memory index = Double({value: smartState.index}).add_(ratio);
            exaState.exaSPSupplyState = MarketRewardsState({
                index: index.value.toUint224(),
                block: blockNumber.toUint32()
            });
        } else if (deltaBlocks > 0) {
            smartState.block = blockNumber.toUint32();
        }
    }

    /**
     * @notice Accrue EXA to the market by updating the maturity pool supply index
     * @param fixedLenderAddress The market whose supply index to update
     * @param blockNumber current block number (injected for testing purpuses)
     * @param fixedLenderAddress The market whose supply index to update
     */
    function updateExaMaturitySupplyIndex(
        RewardsState storage fixedLenderState,
        uint blockNumber,
        address fixedLenderAddress
    ) public {
        ExaState storage exaState = fixedLenderState.exaState[fixedLenderAddress];
        MarketRewardsState storage supplyState = exaState.exaMPSupplyState;
        uint supplySpeed = exaState.exaSpeed;
        uint deltaBlocks = (blockNumber - uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 supplyTokens = IFixedLender(fixedLenderAddress).totalMpDeposits();
            uint256 exaAccruedDelta = deltaBlocks * supplySpeed;
            Double memory ratio = supplyTokens > 0 ? exaAccruedDelta.fraction(supplyTokens) : Double({value: 0});
            Double memory index = Double({value: supplyState.index}).add_(ratio);
            exaState.exaMPSupplyState = MarketRewardsState({
                index: index.value.toUint224(),
                block: blockNumber.toUint32()
            });
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber.toUint32();
        }
    }

    /**
     * @notice Accrue EXA to the market by updating the maturity pool borrow index
     * @param fixedLenderState RewardsState storage in Auditor
     * @param blockNumber current block number (injected for testing purpuses)
     * @param fixedLenderAddress The market whose borrow index to update
     */
    function updateExaMaturityBorrowIndex(
        RewardsState storage fixedLenderState,
        uint blockNumber,
        address fixedLenderAddress
    ) public {
        ExaState storage exaState = fixedLenderState.exaState[fixedLenderAddress];
        MarketRewardsState storage borrowState = exaState.exaMPBorrowState;
        uint borrowSpeed = exaState.exaSpeed;
        uint deltaBlocks = blockNumber - uint(borrowState.block);
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = IFixedLender(fixedLenderAddress).totalMpBorrows();
            uint256 exaAccruedDelta = deltaBlocks * borrowSpeed;

            Double memory ratio = borrowAmount > 0 ? exaAccruedDelta.fraction(borrowAmount) : Double({value: 0});
            Double memory index = Double({value: borrowState.index}).add_(ratio);

            exaState.exaMPBorrowState = MarketRewardsState({
                index: index.value.toUint224(),
                block: blockNumber.toUint32()
            });
        } else if (deltaBlocks > 0) {
            borrowState.block = blockNumber.toUint32();
        }
    }

    /**
     * @notice INTERNAL Calculate EXA accrued by a smart pool supplier and possibly transfer them to him
     * @param fixedLenderState RewardsState storage in Auditor
     * @param fixedLenderAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function _distributeSmartSupplierExa(
        RewardsState storage fixedLenderState,
        address fixedLenderAddress,
        address supplier
    ) internal {
        ExaState storage exaState = fixedLenderState.exaState[fixedLenderAddress];
        MarketRewardsState storage smartState = exaState.exaSPSupplyState;
        Double memory smartPoolIndex = Double({value: smartState.index});
        Double memory smartSupplierIndex = Double({value: exaState.exaSPSupplierIndex[supplier]});
        exaState.exaSPSupplierIndex[supplier] = smartPoolIndex.value;

        if (smartSupplierIndex.value == 0 && smartPoolIndex.value > 0) {
            smartSupplierIndex.value = EXA_INITIAL_INDEX;
        }

        Double memory deltaIndex = smartPoolIndex.sub_(smartSupplierIndex);

        uint smartSupplierTokens = IFixedLender(fixedLenderAddress).eToken().balanceOf(supplier);
        uint smartSupplierDelta = smartSupplierTokens.mul_(deltaIndex);
        uint smartSupplierAccrued = fixedLenderState.exaAccruedUser[supplier] + smartSupplierDelta;
        fixedLenderState.exaAccruedUser[supplier] = smartSupplierAccrued;
        emit DistributedSmartSupplierExa(fixedLenderAddress, supplier, smartSupplierDelta, smartPoolIndex.value);
    }

    /**
     * @notice INTERNAL Calculate EXA accrued by a maturity pool supplier and possibly transfer them to him
     * @param fixedLenderState RewardsState storage in Auditor
     * @param fixedLenderAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function _distributeMaturitySupplierExa(
        RewardsState storage fixedLenderState,
        address fixedLenderAddress,
        address supplier
    ) internal {
        ExaState storage exaState = fixedLenderState.exaState[fixedLenderAddress];
        MarketRewardsState storage supplyState = exaState.exaMPSupplyState;
        Double memory supplyIndex = Double({value: supplyState.index});
        Double memory supplierIndex = Double({value: exaState.exaMPSupplierIndex[supplier]});
        exaState.exaMPSupplierIndex[supplier] = supplyIndex.value;

        if (supplierIndex.value == 0 && supplyIndex.value > 0) {
            supplierIndex.value = EXA_INITIAL_INDEX;
        }

        Double memory deltaIndex = supplyIndex.sub_(supplierIndex);

        uint supplierTokens = IFixedLender(fixedLenderAddress).totalMpDepositsUser(supplier);
        uint supplierDelta = supplierTokens.mul_(deltaIndex);
        uint supplierAccrued = fixedLenderState.exaAccruedUser[supplier] + supplierDelta;
        fixedLenderState.exaAccruedUser[supplier] = supplierAccrued;
        emit DistributedMPSupplierExa(fixedLenderAddress, supplier, supplierDelta, supplyIndex.value);
    }

    /**
     * @notice INTERNAL Calculate EXA accrued by a maturity pool borrower
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param fixedLenderAddress The market address in which the borrower is interacting
     * @param borrower The address of the borrower to distribute EXA to
     */
    function _distributeMaturityBorrowerExa(
        RewardsState storage fixedLenderState,
        address fixedLenderAddress,
        address borrower
    ) internal {
        ExaState storage exaState = fixedLenderState.exaState[fixedLenderAddress];
        MarketRewardsState storage borrowState = exaState.exaMPBorrowState;

        Double memory borrowIndex = Double({value: borrowState.index});
        Double memory borrowerIndex = Double({value: exaState.exaMPBorrowerIndex[borrower]});
        exaState.exaMPBorrowerIndex[borrower] = borrowIndex.value;

        if (borrowerIndex.value > 0) {
            Double memory deltaIndex = borrowIndex.sub_(borrowerIndex);
            uint borrowerAmount = IFixedLender(fixedLenderAddress).totalMpBorrowsUser(borrower);
            uint borrowerDelta = borrowerAmount.mul_(deltaIndex);
            uint borrowerAccrued = fixedLenderState.exaAccruedUser[borrower] + borrowerDelta;
            fixedLenderState.exaAccruedUser[borrower] = borrowerAccrued;
            emit DistributedMaturityBorrowerExa(fixedLenderAddress, borrower, borrowerDelta, borrowIndex.value);
        }
    }

    /**
     * @notice Transfer EXA to the user
     * @param fixedLenderState RewardsState storage in Auditor
     * @param user The address of the user to transfer EXA to
     * @param amount The amount of EXA to (possibly) transfer
     * @return The amount of EXA which was NOT transferred to the user
     */
    function _grantExa(
        RewardsState storage fixedLenderState,
        address user,
        uint amount
    ) internal returns (uint) {
        ExaToken exa = ExaToken(fixedLenderState.exaToken);
        uint exaBalance = exa.balanceOf(address(this));
        if (amount > 0 && amount <= exaBalance) {
            exa.transfer(user, amount);
            return 0;
        }
        return amount;
    }
}
