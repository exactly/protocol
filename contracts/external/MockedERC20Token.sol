// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../EToken.sol";

// mock class using EToken
contract MockedERCToken is EToken {
    constructor(string memory name, string memory symbol) EToken(name, symbol) {
    }

    function transferInternal(
        address from,
        address to,
        uint256 value
    ) public {
        _transfer(from, to, value);
    }

    function approveInternal(
        address owner,
        address spender,
        uint256 value
    ) public {
        _approve(owner, spender, value);
    }
}
