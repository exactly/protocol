// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockedToken is ERC20 {
    uint8 private immutable storedDecimals;
    uint256 private transferCommission = 0;

    /**
     * @dev Constructor that gives msg.sender all of existing tokens.
     */
    constructor(
        string memory name,
        string memory symbol,
        uint8 _decimals,
        uint256 initialSupply
    ) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
        storedDecimals = _decimals;
    }

    function setCommission(uint256 _transferCommission) public {
        transferCommission = _transferCommission;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        amount = ((amount * (1e18 - transferCommission)) / 1e18);
        return super.transferFrom(sender, recipient, amount);
    }

    function transfer(address recipient, uint256 amount)
        public
        override
        returns (bool)
    {
        amount = ((amount * (1e18 - transferCommission)) / 1e18);
        return super.transfer(recipient, amount);
    }
}
