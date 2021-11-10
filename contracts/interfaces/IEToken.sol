// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IEToken is IERC20 {
  /**
    * @dev Mints `amount` eTokens to `user`
    * @param user The address receiving the minted tokens
    * @param amount The amount of tokens getting minted
    */
  function mint(
    address user,
    uint256 amount
  ) external;

  /**
    * @dev Burns eTokens from `user`
    * @param user The owner of the eTokens, getting them burned
    * @param amount The amount being burned
    **/
  function burn(
    address user,
    uint256 amount
  ) external;

  /**
    * @dev Increases contract earnings
    * @param amount The amount of underlying tokens deposited
    */
  function accrueEarnings(uint256 amount) external;

}
