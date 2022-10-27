// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";

/// @dev Used only for testing purposes.
contract MockStETH is ERC20 {
  uint256 public pooledEthByShares;

  constructor(uint256 pooledEthByShares_) ERC20("stETH", "stETH", 18) {
    setPooledEthByShares(pooledEthByShares_);
  }

  function getPooledEthByShares(uint256) external view returns (uint256) {
    return pooledEthByShares;
  }

  function setPooledEthByShares(uint256 pooledEthByShares_) public {
    pooledEthByShares = pooledEthByShares_;
  }

  function mint(address to, uint256 value) public virtual {
    _mint(to, value);
  }
}
