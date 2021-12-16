// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

contract MockedAuditor {
    constructor() {}

    function beforeTransferSP(
        address,
        address,
        address
    ) external {}
}
