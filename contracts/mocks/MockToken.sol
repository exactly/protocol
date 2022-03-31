// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { ERC20 } from "@rari-capital/solmate/src/tokens/ERC20.sol";
import { IFlashBorrower } from "./IFlashBorrower.sol";

contract MockToken is ERC20 {
  /// @dev Constructor that gives msg.sender all of existing tokens.
  constructor(
    string memory name_,
    string memory symbol_,
    uint8 decimals_,
    uint256 initialSupply
  ) ERC20(name_, symbol_, decimals_) {
    _mint(msg.sender, initialSupply);
  }

  function flashLoan(uint256 amount) external {
    _mint(msg.sender, amount);
    IFlashBorrower(msg.sender).doThingsWithFlashLoan();
    _burn(msg.sender, amount);
  }
}
