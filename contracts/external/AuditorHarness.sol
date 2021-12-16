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

    constructor(address _exaToken) {
        rewardsState.exaToken = _exaToken;
    }

    /**
     * @notice Set EXA speed for a single market
     * @param fixedLenderAddress The market whose EXA speed to update
     * @param exaSpeed New EXA speed for market
     */
    function setExaSpeed(address fixedLenderAddress, uint256 exaSpeed)
        external
    {
        require(
            rewardsState.setExaSpeed(
                blockNumber,
                fixedLenderAddress,
                exaSpeed
            ) == true,
            "Error setExaSpeed"
        );
    }

    function refreshIndexes(address fixedLenderAddress) external {
        updateExaMPSupplyIndex(fixedLenderAddress);
        updateExaMPBorrowIndex(fixedLenderAddress);
    }

    function grantExa(address user, uint256 amount) external returns (uint256) {
        return rewardsState.grantExa(user, amount);
    }

    function setBlockNumber(uint256 _blockNumber) public {
        blockNumber = _blockNumber;
    }

    function updateExaSPSupplyIndex(address fixedLenderAddress) public {
        rewardsState.updateExaSPSupplyIndex(blockNumber, fixedLenderAddress);
    }

    function updateExaMPBorrowIndex(address fixedLenderAddress) public {
        rewardsState.updateExaMPBorrowIndex(blockNumber, fixedLenderAddress);
    }

    function updateExaMPSupplyIndex(address fixedLenderAddress) public {
        rewardsState.updateExaMPSupplyIndex(blockNumber, fixedLenderAddress);
    }

    function setExaSPSupplyState(
        address fixedLenderAddress,
        uint224 index,
        uint32 _blockNumber
    ) public {
        rewardsState
            .exaState[fixedLenderAddress]
            .exaSPSupplyState
            .index = index;
        rewardsState
            .exaState[fixedLenderAddress]
            .exaSPSupplyState
            .block = _blockNumber;
    }

    function setExaMPSupplyState(
        address fixedLenderAddress,
        uint224 index,
        uint32 _blockNumber
    ) public {
        rewardsState
            .exaState[fixedLenderAddress]
            .exaMPSupplyState
            .index = index;
        rewardsState
            .exaState[fixedLenderAddress]
            .exaMPSupplyState
            .block = _blockNumber;
    }

    function setExaMPBorrowState(
        address fixedLenderAddress,
        uint224 index,
        uint32 _blockNumber
    ) public {
        rewardsState
            .exaState[fixedLenderAddress]
            .exaMPBorrowState
            .index = index;
        rewardsState
            .exaState[fixedLenderAddress]
            .exaMPBorrowState
            .block = _blockNumber;
    }

    function setExaMPBorrowerIndex(
        address fixedLenderAddress,
        address borrower,
        uint256 index
    ) public {
        rewardsState.exaState[fixedLenderAddress].exaMPBorrowerIndex[
            borrower
        ] = index;
    }

    function setExaSPSupplierIndex(
        address fixedLenderAddress,
        address supplier,
        uint256 index
    ) public {
        rewardsState.exaState[fixedLenderAddress].exaSPSupplierIndex[
            supplier
        ] = index;
    }

    function setExaMPSupplierIndex(
        address fixedLenderAddress,
        address supplier,
        uint256 index
    ) public {
        rewardsState.exaState[fixedLenderAddress].exaMPSupplierIndex[
            supplier
        ] = index;
    }

    function distributeMPBorrowerExa(
        address fixedLenderAddress,
        address borrower
    ) public {
        rewardsState.distributeMPBorrowerExa(fixedLenderAddress, borrower);
    }

    function distributeAllMPBorrowerExa(
        address fixedLenderAddress,
        address borrower
    ) public {
        rewardsState.distributeMPBorrowerExa(fixedLenderAddress, borrower);
        rewardsState.exaAccruedUser[borrower] = rewardsState.grantExa(
            borrower,
            rewardsState.exaAccruedUser[borrower]
        );
    }

    function distributeMPSupplierExa(
        address fixedLenderAddress,
        address supplier
    ) public {
        rewardsState.distributeMPSupplierExa(fixedLenderAddress, supplier);
    }

    function distributeAllMPSupplierExa(
        address fixedLenderAddress,
        address supplier
    ) public {
        rewardsState.distributeMPSupplierExa(fixedLenderAddress, supplier);
        rewardsState.exaAccruedUser[supplier] = rewardsState.grantExa(
            supplier,
            rewardsState.exaAccruedUser[supplier]
        );
    }

    function distributeSPSupplierExa(
        address fixedLenderAddress,
        address supplier
    ) public {
        rewardsState.distributeSPSupplierExa(fixedLenderAddress, supplier);
    }

    function distributeAllSPSupplierExa(
        address fixedLenderAddress,
        address supplier
    ) public {
        rewardsState.distributeSPSupplierExa(fixedLenderAddress, supplier);
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

    function getSmartSupplyState(address fixedLenderAddress)
        public
        view
        returns (MarketRewardsState memory)
    {
        return rewardsState.exaState[fixedLenderAddress].exaSPSupplyState;
    }

    function getMaturitySupplyState(address fixedLenderAddress)
        public
        view
        returns (MarketRewardsState memory)
    {
        return rewardsState.exaState[fixedLenderAddress].exaMPSupplyState;
    }

    function getBorrowState(address fixedLenderAddress)
        public
        view
        returns (MarketRewardsState memory)
    {
        return rewardsState.exaState[fixedLenderAddress].exaMPBorrowState;
    }

    function getExaAccrued(address who) public view returns (uint256) {
        return rewardsState.exaAccruedUser[who];
    }
}
