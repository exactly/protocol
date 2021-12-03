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
        mapping(address => uint256) exaAccruedUser;
    }

    // Double precision
    uint224 public constant EXA_INITIAL_INDEX = 1e36;

    event DistributedMPSupplierExa(
        address indexed fixedLender,
        address indexed supplier,
        uint256 mpSupplierDelta,
        uint256 exaMPSupplyIndex
    );
    event DistributedMPBorrowerExa(
        address indexed fixedLender,
        address indexed borrower,
        uint256 mpBorrowerDelta,
        uint256 exaMPBorrowIndex
    );
    event DistributedSPSupplierExa(
        address indexed fixedLender,
        address indexed supplier,
        uint256 spSupplierDelta,
        uint256 exaSPSupplyIndex
    );

    /**
     * @notice Calculate EXA accrued by a smart pool supplier
     * @param fixedLenderState RewardsState storage in Auditor
     * @param fixedLenderAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function distributeSPSupplierExa(
        RewardsState storage fixedLenderState,
        address fixedLenderAddress,
        address supplier
    ) external {
        _distributeSPSupplierExa(
            fixedLenderState,
            fixedLenderAddress,
            supplier
        );
    }

    /**
     * @notice Calculate EXA accrued by a maturity pool supplier
     * @param fixedLenderState RewardsState storage in Auditor
     * @param fixedLenderAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function distributeMPSupplierExa(
        RewardsState storage fixedLenderState,
        address fixedLenderAddress,
        address supplier
    ) external {
        _distributeMPSupplierExa(
            fixedLenderState,
            fixedLenderAddress,
            supplier
        );
    }

    /**
     * @notice Calculate EXA accrued by a maturity pool borrower
     * @dev Borrowers will not begin to accrue until the first interaction with the protocol.
     * @param fixedLenderAddress The market address in which the borrower is interacting
     * @param borrower The address of the borrower to distribute EXA to
     */
    function distributeMPBorrowerExa(
        RewardsState storage fixedLenderState,
        address fixedLenderAddress,
        address borrower
    ) external {
        _distributeMPBorrowerExa(
            fixedLenderState,
            fixedLenderAddress,
            borrower
        );
    }

    /**
     * @notice Claim all EXA accrued by the holders
     * @param fixedLenderState RewardsState storage in Auditor
     * @param blockNumber current block number (injected for testing purpuses)
     * @param markets Valid markets in Auditor
     * @param holders The addresses to claim EXA for
     * @param fixedLenderAddresses The list of markets to claim EXA in
     * @param mpBorrowers Whether or not to claim EXA earned by maturity pool borrowing
     * @param mpSuppliers Whether or not to claim EXA earned by maturity pool supplying
     * @param spSuppliers Whether or not to claim EXA earned by smart pool supplying
     */
    function claimExa(
        RewardsState storage fixedLenderState,
        uint256 blockNumber,
        mapping(address => MarketsLib.Market) storage markets,
        address[] memory holders,
        address[] memory fixedLenderAddresses,
        bool mpBorrowers,
        bool mpSuppliers,
        bool spSuppliers
    ) external {
        for (uint256 i = 0; i < fixedLenderAddresses.length; i++) {
            address fixedLender = fixedLenderAddresses[i];
            MarketsLib.Market storage market = markets[fixedLender];

            if (!market.isListed) {
                revert GenericError(ErrorCode.MARKET_NOT_LISTED);
            }

            if (mpBorrowers == true) {
                updateExaMPBorrowIndex(
                    fixedLenderState,
                    blockNumber,
                    fixedLender
                );
                for (uint256 j = 0; j < holders.length; j++) {
                    _distributeMPBorrowerExa(
                        fixedLenderState,
                        fixedLender,
                        holders[j]
                    );
                    fixedLenderState.exaAccruedUser[holders[j]] = _grantExa(
                        fixedLenderState,
                        holders[j],
                        fixedLenderState.exaAccruedUser[holders[j]]
                    );
                }
            }
            if (mpSuppliers == true) {
                updateExaMPSupplyIndex(
                    fixedLenderState,
                    blockNumber,
                    fixedLender
                );
                for (uint256 j = 0; j < holders.length; j++) {
                    _distributeMPSupplierExa(
                        fixedLenderState,
                        fixedLender,
                        holders[j]
                    );
                    fixedLenderState.exaAccruedUser[holders[j]] = _grantExa(
                        fixedLenderState,
                        holders[j],
                        fixedLenderState.exaAccruedUser[holders[j]]
                    );
                }
            }

            if (spSuppliers == true) {
                updateExaSPSupplyIndex(
                    fixedLenderState,
                    blockNumber,
                    fixedLender
                );
                for (uint256 j = 0; j < holders.length; j++) {
                    _distributeSPSupplierExa(
                        fixedLenderState,
                        fixedLender,
                        holders[j]
                    );
                    fixedLenderState.exaAccruedUser[holders[j]] = _grantExa(
                        fixedLenderState,
                        holders[j],
                        fixedLenderState.exaAccruedUser[holders[j]]
                    );
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
        uint256 amount
    ) external returns (uint256) {
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
        uint256 blockNumber,
        address fixedLenderAddress,
        uint256 exaSpeed
    ) external returns (bool) {
        ExaState storage state = fixedLenderState.exaState[fixedLenderAddress];
        uint256 currentExaSpeed = state.exaSpeed;
        if (currentExaSpeed != 0) {
            updateExaMPSupplyIndex(
                fixedLenderState,
                blockNumber,
                fixedLenderAddress
            );
            updateExaMPBorrowIndex(
                fixedLenderState,
                blockNumber,
                fixedLenderAddress
            );
            updateExaSPSupplyIndex(
                fixedLenderState,
                blockNumber,
                fixedLenderAddress
            );
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
    function updateExaSPSupplyIndex(
        RewardsState storage fixedLenderState,
        uint256 blockNumber,
        address fixedLenderAddress
    ) public {
        ExaState storage exaState = fixedLenderState.exaState[
            fixedLenderAddress
        ];
        MarketRewardsState storage spSupplyState = exaState.exaSPSupplyState;
        uint256 supplySpeed = exaState.exaSpeed;
        uint256 deltaBlocks = (blockNumber - uint256(spSupplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 spTokens = IFixedLender(fixedLenderAddress)
                .eToken()
                .totalSupply();
            uint256 exaAccruedDelta = deltaBlocks * supplySpeed;
            Double memory ratio = spTokens > 0
                ? exaAccruedDelta.fraction(spTokens)
                : Double({value: 0});
            Double memory index = Double({value: spSupplyState.index}).add_(
                ratio
            );
            exaState.exaSPSupplyState = MarketRewardsState({
                index: index.value.toUint224(),
                block: blockNumber.toUint32()
            });
        } else if (deltaBlocks > 0) {
            spSupplyState.block = blockNumber.toUint32();
        }
    }

    /**
     * @notice Accrue EXA to the market by updating the maturity pool supply index
     * @param fixedLenderAddress The market whose supply index to update
     * @param blockNumber current block number (injected for testing purpuses)
     * @param fixedLenderAddress The market whose supply index to update
     */
    function updateExaMPSupplyIndex(
        RewardsState storage fixedLenderState,
        uint256 blockNumber,
        address fixedLenderAddress
    ) public {
        ExaState storage exaState = fixedLenderState.exaState[
            fixedLenderAddress
        ];
        MarketRewardsState storage mpSupplyState = exaState.exaMPSupplyState;
        uint256 supplySpeed = exaState.exaSpeed;
        uint256 deltaBlocks = (blockNumber - uint256(mpSupplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 mpSupplyTokens = IFixedLender(fixedLenderAddress)
                .totalMpDeposits();
            uint256 exaAccruedDelta = deltaBlocks * supplySpeed;
            Double memory ratio = mpSupplyTokens > 0
                ? exaAccruedDelta.fraction(mpSupplyTokens)
                : Double({value: 0});
            Double memory index = Double({value: mpSupplyState.index}).add_(
                ratio
            );
            exaState.exaMPSupplyState = MarketRewardsState({
                index: index.value.toUint224(),
                block: blockNumber.toUint32()
            });
        } else if (deltaBlocks > 0) {
            mpSupplyState.block = blockNumber.toUint32();
        }
    }

    /**
     * @notice Accrue EXA to the market by updating the maturity pool borrow index
     * @param fixedLenderState RewardsState storage in Auditor
     * @param blockNumber current block number (injected for testing purpuses)
     * @param fixedLenderAddress The market whose borrow index to update
     */
    function updateExaMPBorrowIndex(
        RewardsState storage fixedLenderState,
        uint256 blockNumber,
        address fixedLenderAddress
    ) public {
        ExaState storage exaState = fixedLenderState.exaState[
            fixedLenderAddress
        ];
        MarketRewardsState storage mpBorrowState = exaState.exaMPBorrowState;
        uint256 borrowSpeed = exaState.exaSpeed;
        uint256 deltaBlocks = blockNumber - uint256(mpBorrowState.block);
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint256 borrowAmount = IFixedLender(fixedLenderAddress)
                .totalMpBorrows();
            uint256 exaAccruedDelta = deltaBlocks * borrowSpeed;

            Double memory ratio = borrowAmount > 0
                ? exaAccruedDelta.fraction(borrowAmount)
                : Double({value: 0});
            Double memory index = Double({value: mpBorrowState.index}).add_(
                ratio
            );

            exaState.exaMPBorrowState = MarketRewardsState({
                index: index.value.toUint224(),
                block: blockNumber.toUint32()
            });
        } else if (deltaBlocks > 0) {
            mpBorrowState.block = blockNumber.toUint32();
        }
    }

    /**
     * @notice INTERNAL Calculate EXA accrued by a smart pool supplier
     * @param fixedLenderState RewardsState storage in Auditor
     * @param fixedLenderAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function _distributeSPSupplierExa(
        RewardsState storage fixedLenderState,
        address fixedLenderAddress,
        address supplier
    ) internal {
        ExaState storage exaState = fixedLenderState.exaState[
            fixedLenderAddress
        ];
        MarketRewardsState storage spSupplyState = exaState.exaSPSupplyState;
        Double memory spSupplyIndex = Double({value: spSupplyState.index});
        Double memory spSupplierIndex = Double({
            value: exaState.exaSPSupplierIndex[supplier]
        });
        exaState.exaSPSupplierIndex[supplier] = spSupplyIndex.value;

        if (spSupplierIndex.value == 0 && spSupplyIndex.value > 0) {
            spSupplierIndex.value = EXA_INITIAL_INDEX;
        }

        Double memory deltaIndex = spSupplyIndex.sub_(spSupplierIndex);

        uint256 spSupplierTokens = IFixedLender(fixedLenderAddress)
            .eToken()
            .balanceOf(supplier);
        uint256 spSupplierDelta = spSupplierTokens.mul_(deltaIndex);
        uint256 spSupplierAccrued = fixedLenderState.exaAccruedUser[supplier] +
            spSupplierDelta;
        fixedLenderState.exaAccruedUser[supplier] = spSupplierAccrued;
        emit DistributedSPSupplierExa(
            fixedLenderAddress,
            supplier,
            spSupplierDelta,
            spSupplyIndex.value
        );
    }

    /**
     * @notice INTERNAL Calculate EXA accrued by a maturity pool supplier
     * @param fixedLenderState RewardsState storage in Auditor
     * @param fixedLenderAddress The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute EXA to
     */
    function _distributeMPSupplierExa(
        RewardsState storage fixedLenderState,
        address fixedLenderAddress,
        address supplier
    ) internal {
        ExaState storage exaState = fixedLenderState.exaState[
            fixedLenderAddress
        ];
        MarketRewardsState storage mpSupplyState = exaState.exaMPSupplyState;
        Double memory mpSupplyIndex = Double({value: mpSupplyState.index});
        Double memory mpSupplierIndex = Double({
            value: exaState.exaMPSupplierIndex[supplier]
        });
        exaState.exaMPSupplierIndex[supplier] = mpSupplyIndex.value;

        if (mpSupplierIndex.value == 0 && mpSupplyIndex.value > 0) {
            mpSupplierIndex.value = EXA_INITIAL_INDEX;
        }

        Double memory deltaIndex = mpSupplyIndex.sub_(mpSupplierIndex);

        uint256 mpSupplierTokens = IFixedLender(fixedLenderAddress)
            .totalMpDepositsUser(supplier);
        uint256 mpSupplierDelta = mpSupplierTokens.mul_(deltaIndex);
        uint256 mpSupplierAccrued = fixedLenderState.exaAccruedUser[supplier] +
            mpSupplierDelta;
        fixedLenderState.exaAccruedUser[supplier] = mpSupplierAccrued;
        emit DistributedMPSupplierExa(
            fixedLenderAddress,
            supplier,
            mpSupplierDelta,
            mpSupplyIndex.value
        );
    }

    /**
     * @notice INTERNAL Calculate EXA accrued by a maturity pool borrower
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param fixedLenderAddress The market address in which the borrower is interacting
     * @param borrower The address of the borrower to distribute EXA to
     */
    function _distributeMPBorrowerExa(
        RewardsState storage fixedLenderState,
        address fixedLenderAddress,
        address borrower
    ) internal {
        ExaState storage exaState = fixedLenderState.exaState[
            fixedLenderAddress
        ];
        MarketRewardsState storage mpBorrowState = exaState.exaMPBorrowState;

        Double memory mpBorrowIndex = Double({value: mpBorrowState.index});
        Double memory mpBorrowerIndex = Double({
            value: exaState.exaMPBorrowerIndex[borrower]
        });
        exaState.exaMPBorrowerIndex[borrower] = mpBorrowIndex.value;

        if (mpBorrowerIndex.value > 0) {
            Double memory deltaIndex = mpBorrowIndex.sub_(mpBorrowerIndex);
            uint256 mpBorrowerAmount = IFixedLender(fixedLenderAddress)
                .totalMpBorrowsUser(borrower);
            uint256 mpBorrowerDelta = mpBorrowerAmount.mul_(deltaIndex);
            uint256 mpBorrowerAccrued = fixedLenderState.exaAccruedUser[
                borrower
            ] + mpBorrowerDelta;
            fixedLenderState.exaAccruedUser[borrower] = mpBorrowerAccrued;
            emit DistributedMPBorrowerExa(
                fixedLenderAddress,
                borrower,
                mpBorrowerDelta,
                mpBorrowIndex.value
            );
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
        uint256 amount
    ) internal returns (uint256) {
        ExaToken exa = ExaToken(fixedLenderState.exaToken);
        uint256 exaBalance = exa.balanceOf(address(this));
        if (amount > 0 && amount <= exaBalance) {
            exa.transfer(user, amount);
            return 0;
        }
        return amount;
    }
}
