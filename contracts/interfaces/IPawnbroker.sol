// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IPawnbroker {
    function addCollateral(address, address, uint256) external;
    function withdrawCollateral(address, address, uint256) external;

    function isCollateralized(address user) external view returns (bool);
}
