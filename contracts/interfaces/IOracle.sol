// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

/**
 * @title IOracle interface
 * @notice Interface for the Exactly oracle.
 **/

interface IOracle {
  /**
   * @dev returns the asset price
   * @param symbol the symbol of the asset
   * @return the price of the asset
   **/
  function getAssetPrice(string memory symbol) external view returns (uint256);
}
