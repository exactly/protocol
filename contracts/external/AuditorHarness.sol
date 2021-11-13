// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/DecimalMath.sol";
import "../utils/ExaLib.sol";
import "../utils/MarketsLib.sol";

contract AuditorHarness {
    using DecimalMath for uint256;
    using ExaLib for ExaLib.RewardsState;
    using MarketsLib for MarketsLib.Book;

    event DistributedSupplierExa(
        address indexed exafin,
        address indexed supplier,
        uint256 supplierDelta,
        uint256 exaSupplyIndex
    );
    event DistributedBorrowerExa(
        address indexed exafin,
        address indexed borrower,
        uint256 borrowerDelta,
        uint256 exaSupplyIndex
    );
    event DistributedSmartPoolExa(
        address indexed exafin,
        address indexed supplier,
        uint smartSupplierDelta,
        uint smartPoolIndex
    );

    uint256 public blockNumber;
    address[] public marketAddresses;

    // Rewards Management
    ExaLib.RewardsState public rewardsState;
    // Protocol Management
    MarketsLib.Book private book;

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
            rewardsState.setExaSpeed(blockNumber, exafinAddress, exaSpeed) ==
                true,
            "Error setExaSpeed"
        );
    }

    function getSmartState(address exafinAddress)
        public
        view
        returns (MarketRewardsState memory)
    {
        return rewardsState.exaState[exafinAddress].exaSmartState;
    }

    function getSupplyState(address exafinAddress)
        public
        view
        returns (MarketRewardsState memory)
    {
        return rewardsState.exaState[exafinAddress].exaSupplyState;
    }

    function getBorrowState(address exafinAddress)
        public
        view
        returns (MarketRewardsState memory)
    {
        return rewardsState.exaState[exafinAddress].exaBorrowState;
    }

    function updateExaSmartPoolIndex(address exafinAddress) public {
        rewardsState.updateExaSmartPoolIndex(blockNumber, exafinAddress);
    }

    function updateExaBorrowIndex(address exafinAddress) public {
        rewardsState.updateExaBorrowIndex(blockNumber, exafinAddress);
    }

    function updateExaSupplyIndex(address exafinAddress) public {
        rewardsState.updateExaSupplyIndex(blockNumber, exafinAddress);
    }

    function refreshIndexes(address exafinAddress) external {
        updateExaSupplyIndex(exafinAddress);
        updateExaBorrowIndex(exafinAddress);
    }

    function setExaSmartState(
        address exafinAddress,
        uint224 index,
        uint32 _blockNumber
    ) public {
        rewardsState.exaState[exafinAddress].exaSmartState.index = index;
        rewardsState.exaState[exafinAddress].exaSmartState.block = _blockNumber;
    }

    function setExaSupplyState(
        address exafinAddress,
        uint224 index,
        uint32 _blockNumber
    ) public {
        rewardsState.exaState[exafinAddress].exaSupplyState.index = index;
        rewardsState
            .exaState[exafinAddress]
            .exaSupplyState
            .block = _blockNumber;
    }

    function setExaBorrowState(
        address exafinAddress,
        uint224 index,
        uint32 _blockNumber
    ) public {
        rewardsState.exaState[exafinAddress].exaBorrowState.index = index;
        rewardsState
            .exaState[exafinAddress]
            .exaBorrowState
            .block = _blockNumber;
    }

    function setExaBorrowerIndex(
        address exafinAddress,
        address borrower,
        uint256 index
    ) public {
        rewardsState.exaState[exafinAddress].exaBorrowerIndex[borrower] = index;
    }

    function setExaSmartSupplierIndex(
        address exafinAddress,
        address supplier,
        uint256 index
    ) public {
        rewardsState.exaState[exafinAddress].exaSmartSupplierIndex[
            supplier
        ] = index;
    }

    function setExaSupplierIndex(
        address exafinAddress,
        address supplier,
        uint256 index
    ) public {
        rewardsState.exaState[exafinAddress].exaSupplierIndex[supplier] = index;
    }

    function distributeBorrowerExa(address exafinAddress, address borrower)
        public
    {
        rewardsState.distributeBorrowerExa(exafinAddress, borrower);
    }

    function distributeAllBorrowerExa(address exafinAddress, address borrower)
        public
    {
        rewardsState.distributeBorrowerExa(exafinAddress, borrower);
        rewardsState.exaAccruedUser[borrower] = rewardsState.grantExa(
            borrower,
            rewardsState.exaAccruedUser[borrower]
        );
    }

    function distributeSupplierExa(address exafinAddress, address supplier)
        public
    {
        rewardsState.distributeSupplierExa(exafinAddress, supplier);
    }

    function distributeAllSupplierExa(address exafinAddress, address supplier)
        public
    {
        rewardsState.distributeSupplierExa(exafinAddress, supplier);
        rewardsState.exaAccruedUser[supplier] = rewardsState.grantExa(
            supplier,
            rewardsState.exaAccruedUser[supplier]
        );
    }

    function distributeSmartPoolExa(address exafinAddress, address supplier)
        public
    {
        rewardsState.distributeSmartPoolExa(exafinAddress, supplier);
    }

    function distributeAllSmartPoolExa(address exafinAddress, address supplier)
        public
    {
        rewardsState.distributeSmartPoolExa(exafinAddress, supplier);
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

    function grantExa(address user, uint256 amount) external returns (uint256) {
        return rewardsState.grantExa(user, amount);
    }

    function claimExaAll(address holder) public {
        return claimExa(holder, marketAddresses);
    }

    function claimExa(address holder, address[] memory exafins) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        rewardsState.claimExa(
            blockNumber,
            book.markets,
            holders,
            exafins,
            true,
            true,
            true
        );
    }

    function enableMarket(address exafin) public {
        MarketsLib.Market storage market = book.markets[exafin];
        market.isListed = true;

        marketAddresses.push(exafin);
    }
}
