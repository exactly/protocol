// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/DecimalMath.sol";
import "../utils/ExaLib.sol";

interface ISomeExafin {
    function totalBorrows() external view returns (uint256);
    function totalDeposits() external view returns (uint256);
    function borrowsOf(address who) external view returns (uint256);
    function suppliesOf(address who) external view returns (uint256);
}

contract SomeExafin is ISomeExafin {
    uint256 override public totalBorrows;
    uint256 override public totalDeposits;
    mapping(address => uint256) override public borrowsOf;
    mapping(address => uint256) override public suppliesOf;

    function setTotalBorrows(uint _totalBorrows) public {
        totalBorrows = _totalBorrows;
    }

    function setTotalDeposits(uint _totalDeposits) public {
        totalDeposits = _totalDeposits;
    }

    function setBorrowsOf(address _who, uint256 _amount) public {
        borrowsOf[_who] = _amount;
    }

    function setSuppliesOf(address _who, uint256 _amount) public {
        suppliesOf[_who] = _amount;
    }
}
