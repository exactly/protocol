// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IyDAI is IERC20 {
    function withdraw(uint256 _shares) external;
    function deposit(uint256 _amount) external;
    function getPricePerFullShare() external view returns (uint256);
}
