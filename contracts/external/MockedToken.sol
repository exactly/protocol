// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockedToken is ERC20 {
    uint8 private immutable storedDecimals;
    /**
     * @dev Constructor that gives msg.sender all of existing tokens.
     */
    constructor(string memory name, string memory symbol, uint8 _decimals, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
        storedDecimals = _decimals;
    }
    function decimals() public view virtual override returns (uint8) {
        return storedDecimals;
    }
}
