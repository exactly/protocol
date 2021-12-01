// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../interfaces/IFixedLender.sol";
import "../interfaces/IAuditor.sol";

contract EvilFixedLender {
    address public auditor;

    constructor(address _auditor) {
        auditor = _auditor;
    }

    function evilLiquidate(
        address anotherExafinToSeize,
        address borrower,
        uint256 seizeTokens,
        uint256 maturityDate
    ) public {
        IFixedLender(anotherExafinToSeize).seize(
            msg.sender,
            borrower,
            seizeTokens,
            maturityDate
        );
    }

    function getAuditor() public view returns (IAuditor) {
        return IAuditor(auditor);
    }
}
