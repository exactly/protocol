// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

contract MockedAuditor {
    constructor() {} // solhint-disable-line no-empty-blocks

    function validateAccountShortfall(
        address,
        address,
        uint256
    ) external {} // solhint-disable-line no-empty-blocks
}
