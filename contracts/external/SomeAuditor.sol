// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/DecimalMath.sol";
import "../utils/ExaLib.sol";

contract SomeAuditor {

    using DecimalMath for uint256;
    using ExaLib for ExaLib.RewardsState;

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
        uint exaSupplyIndex
    );

    uint256 public blockNumber;

    // Rewards Management
    ExaLib.RewardsState public rewardsState;

    constructor(address _exaToken) {
        rewardsState.exaToken = _exaToken;
    }

    function setBlockNumber(uint256 _blockNumber) public {
        blockNumber = _blockNumber;
    }

    /**
     * @notice Set EXA speed for a single market
     * @param exafinAddress The market whose EXA speed to update
     * @param exaSpeed New EXA speed for market
     */
    function setExaSpeed(address exafinAddress, uint256 exaSpeed) external {
        require(
            rewardsState.setExaSpeed(blockNumber, exafinAddress, exaSpeed) == true,
            "Error setExaSpeed"
        );
    }

    function getSupplyState(address exafinAddress) public view returns (MarketRewardsState memory) {
        return rewardsState.exaState[exafinAddress].exaSupplyState;
    }

    function getBorrowState(address exafinAddress) public view returns (MarketRewardsState memory) {
        return rewardsState.exaState[exafinAddress].exaBorrowState;
    }

    function updateExaBorrowIndex(address exafinAddress) external  {
        rewardsState.updateExaBorrowIndex(blockNumber, exafinAddress);
    }

    function updateExaSupplyIndex(address exafinAddress) external  {
        rewardsState.updateExaSupplyIndex(blockNumber, exafinAddress);
    }

    function setExaSupplyState(address exafinAddress, uint224 index, uint32 _blockNumber) public {
        rewardsState.exaState[exafinAddress].exaSupplyState.index = index;
        rewardsState.exaState[exafinAddress].exaSupplyState.block = _blockNumber;
    }

    function setExaBorrowState(address exafinAddress, uint224 index, uint32 _blockNumber) public {
        rewardsState.exaState[exafinAddress].exaBorrowState.index = index;
        rewardsState.exaState[exafinAddress].exaBorrowState.block = _blockNumber;
    }

    function setExaBorrowerIndex(address exafinAddress, address borrower, uint index) public {
        rewardsState.exaState[exafinAddress].exaBorrowerIndex[borrower] = index;
    }

    function setExaSupplierIndex(address exafinAddress, address supplier, uint index) public {
        rewardsState.exaState[exafinAddress].exaSupplierIndex[supplier] = index;
    }

    function distributeBorrowerExa(
        address exafinAddress,
        address borrower
    ) public {
        rewardsState.distributeBorrowerExa(exafinAddress, borrower);
    }

    function distributeAllBorrowerExa(
        address exafinAddress,
        address borrower
    ) public {
        rewardsState.distributeBorrowerExa(exafinAddress, borrower);
        rewardsState.exaAccruedUser[borrower] = rewardsState.grantExa(
            borrower,
            rewardsState.exaAccruedUser[borrower]
        );
    }

    function distributeSupplierExa(
        address exafinAddress,
        address supplier
    ) public {
        rewardsState.distributeSupplierExa(exafinAddress, supplier);
    }

    function distributeAllSupplierExa(
        address exafinAddress,
        address supplier
    ) public {
        rewardsState.distributeSupplierExa(exafinAddress, supplier);
        rewardsState.exaAccruedUser[supplier] = rewardsState.grantExa(
            supplier,
            rewardsState.exaAccruedUser[supplier]
        );
    }

    function getExaAccrued(address who) public view returns (uint256) {
        return rewardsState.exaAccruedUser[who];
    }

    function setExaAccrued(address who, uint256 amount) public {
        rewardsState.exaAccruedUser[who] = amount;
    }

    function grantExa(
        address user,
        uint amount
    ) external returns (uint) {
        return rewardsState.grantExa(user, amount);
    }

}
