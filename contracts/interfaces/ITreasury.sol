// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../utils/IWeth.sol";
import "../utils/Maker.sol";
import "dss-interfaces/src/dss/DaiAbstract.sol";

interface ITreasury {
    function pushWeth(address to, uint256 amountWeth) external;
    function pullWeth(address to, uint256 amountWeth) external;

    function pushDai(address user, uint256 amountDai) external;
    function pullDai(address user, uint256 amountDai) external;

    function debt() external view returns(uint256);
    function savings() external view returns(uint256);

    function weth() external view returns (IWeth);
    function dai() external view returns (DaiAbstract);
}
