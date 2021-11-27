// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/DecimalMath.sol";
import "../utils/ExaLib.sol";
import "../utils/MarketsLib.sol";

contract AuditorHarness {
    using DecimalMath for uint256;
    using ExaLib for ExaLib.RewardsState;
    using MarketsLib for MarketsLib.Book;

    uint256 public blockNumber;
    address[] public marketAddresses;

    // Rewards Management
    ExaLib.RewardsState public rewardsState;
    // Protocol Management
    MarketsLib.Book private book;

    event DistributedSupplierExa(
        address indexed fixedLender,
        address indexed supplier,
        uint256 supplierDelta,
        uint256 exaSupplyIndex
    );
    event DistributedBorrowerExa(
        address indexed fixedLender,
        address indexed borrower,
        uint256 borrowerDelta,
        uint256 exaSupplyIndex
    );
    event DistributedSmartPoolExa(
        address indexed fixedLender,
        address indexed supplier,
        uint smartSupplierDelta,
        uint smartPoolIndex
    );

    constructor(address _exaToken) {
        rewardsState.exaToken = _exaToken;
    }

    /**
     * @notice Set EXA speed for a single market
     * @param fixedLenderAddress The market whose EXA speed to update
     * @param exaSpeed New EXA speed for market
     */
    function setExaSpeed(address fixedLenderAddress, uint256 exaSpeed) external {
        require(
            rewardsState.setExaSpeed(blockNumber, fixedLenderAddress, exaSpeed) ==
                true,
            "Error setExaSpeed"
        );
    }

    function refreshIndexes(address fixedLenderAddress) external {
        updateExaSupplyIndex(fixedLenderAddress);
        updateExaBorrowIndex(fixedLenderAddress);
    }

    function grantExa(address user, uint256 amount) external returns (uint256) {
        return rewardsState.grantExa(user, amount);
    }

    function setBlockNumber(uint256 _blockNumber) public {
        blockNumber = _blockNumber;
    }

    function updateExaSmartPoolIndex(address fixedLenderAddress) public {
        rewardsState.updateExaSmartPoolIndex(blockNumber, fixedLenderAddress);
    }

    function updateExaBorrowIndex(address fixedLenderAddress) public {
        rewardsState.updateExaBorrowIndex(blockNumber, fixedLenderAddress);
    }

    function updateExaSupplyIndex(address fixedLenderAddress) public {
        rewardsState.updateExaSupplyIndex(blockNumber, fixedLenderAddress);
    }

    function setExaSmartState(
        address fixedLenderAddress,
        uint224 index,
        uint32 _blockNumber
    ) public {
        rewardsState.exaState[fixedLenderAddress].exaSmartState.index = index;
        rewardsState.exaState[fixedLenderAddress].exaSmartState.block = _blockNumber;
    }

    function setExaSupplyState(
        address fixedLenderAddress,
        uint224 index,
        uint32 _blockNumber
    ) public {
        rewardsState.exaState[fixedLenderAddress].exaSupplyState.index = index;
        rewardsState
            .exaState[fixedLenderAddress]
            .exaSupplyState
            .block = _blockNumber;
    }

    function setExaBorrowState(
        address fixedLenderAddress,
        uint224 index,
        uint32 _blockNumber
    ) public {
        rewardsState.exaState[fixedLenderAddress].exaBorrowState.index = index;
        rewardsState
            .exaState[fixedLenderAddress]
            .exaBorrowState
            .block = _blockNumber;
    }

    function setExaBorrowerIndex(
        address fixedLenderAddress,
        address borrower,
        uint256 index
    ) public {
        rewardsState.exaState[fixedLenderAddress].exaBorrowerIndex[borrower] = index;
    }

    function setExaSmartSupplierIndex(
        address fixedLenderAddress,
        address supplier,
        uint256 index
    ) public {
        rewardsState.exaState[fixedLenderAddress].exaSmartSupplierIndex[supplier] = index;
    }

    function setExaSupplierIndex(
        address fixedLenderAddress,
        address supplier,
        uint256 index
    ) public {
        rewardsState.exaState[fixedLenderAddress].exaSupplierIndex[supplier] = index;
    }

    function distributeBorrowerExa(address fixedLenderAddress, address borrower)
        public
    {
        rewardsState.distributeBorrowerExa(fixedLenderAddress, borrower);
    }

    function distributeAllBorrowerExa(address fixedLenderAddress, address borrower)
        public
    {
        rewardsState.distributeBorrowerExa(fixedLenderAddress, borrower);
        rewardsState.exaAccruedUser[borrower] = rewardsState.grantExa(
            borrower,
            rewardsState.exaAccruedUser[borrower]
        );
    }

    function distributeSupplierExa(address fixedLenderAddress, address supplier)
        public
    {
        rewardsState.distributeSupplierExa(fixedLenderAddress, supplier);
    }

    function distributeAllSupplierExa(address fixedLenderAddress, address supplier)
        public
    {
        rewardsState.distributeSupplierExa(fixedLenderAddress, supplier);
        rewardsState.exaAccruedUser[supplier] = rewardsState.grantExa(
            supplier,
            rewardsState.exaAccruedUser[supplier]
        );
    }

    function distributeSmartPoolExa(address fixedLenderAddress, address supplier)
        public
    {
        rewardsState.distributeSmartPoolExa(fixedLenderAddress, supplier);
    }

    function distributeAllSmartPoolExa(address fixedLenderAddress, address supplier)
        public
    {
        rewardsState.distributeSmartPoolExa(fixedLenderAddress, supplier);
        rewardsState.exaAccruedUser[supplier] = rewardsState.grantExa(
            supplier,
            rewardsState.exaAccruedUser[supplier]
        );
    }

    function setExaAccrued(address who, uint256 amount) public {
        rewardsState.exaAccruedUser[who] = amount;
    }

    function claimExaAll(address holder) public {
        return claimExa(holder, marketAddresses);
    }

    function claimExa(address holder, address[] memory fixedLenders) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        rewardsState.claimExa(
            blockNumber,
            book.markets,
            holders,
            fixedLenders,
            true,
            true,
            true
        );
    }

    function enableMarket(address fixedLender) public {
        MarketsLib.Market storage market = book.markets[fixedLender];
        market.isListed = true;

        marketAddresses.push(fixedLender);
    }

    function getSmartState(address fixedLenderAddress)
        public
        view
        returns (MarketRewardsState memory)
    {
        return rewardsState.exaState[fixedLenderAddress].exaSmartState;
    }

    function getSupplyState(address fixedLenderAddress)
        public
        view
        returns (MarketRewardsState memory)
    {
        return rewardsState.exaState[fixedLenderAddress].exaSupplyState;
    }

    function getBorrowState(address fixedLenderAddress)
        public
        view
        returns (MarketRewardsState memory)
    {
        return rewardsState.exaState[fixedLenderAddress].exaBorrowState;
    }

    function getExaAccrued(address who) public view returns (uint256) {
        return rewardsState.exaAccruedUser[who];
    }
}
