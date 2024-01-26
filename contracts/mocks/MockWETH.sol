// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { WETH } from "solmate/src/tokens/WETH.sol";

/// @dev Used only for testing purposes.
contract MockWETH is WETH {
  function mint(address to, uint256 value) public virtual {
    _mint(to, value);
  }

  function burn(address from, uint256 value) public virtual {
    _burn(from, value);
  }
}
