// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IEToken is IERC20 {
    /**
     * @dev Mints `amount` eTokens to `user`
     * - Only callable by the Exafin
     * @param user The address receiving the minted tokens
     * @param amount The amount of tokens getting minted
     */
    function mint(address user, uint256 amount) external;

    /**
     * @dev Burns eTokens from `user`
     * - Only callable by the Exafin
     * @param user The owner of the eTokens, getting them burned
     * @param amount The amount being burned
     **/
    function burn(address user, uint256 amount) external;

    /**
     * @dev Increases contract earnings
     * - Only callable by the Exafin
     * @param amount The amount of underlying tokens deposited
     */
    function accrueEarnings(uint256 amount) external;

    /**
     * @dev Emitted when `exafin` is set
     * - The Exafin is where the eToken is used
     */
    event ExafinSet(address indexed exafin);

    /**
     * @dev Emitted when `amount` is accrued as earnings
     */
    event EarningsAccrued(uint256 amount);
}
