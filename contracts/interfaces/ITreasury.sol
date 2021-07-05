// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../utils/IWeth.sol";
import "dss-interfaces/src/dss/GemJoinAbstract.sol";
import "dss-interfaces/src/dss/VatAbstract.sol";

interface ITreasury {
    function pushWeth(address to, uint256 amountWeth) external;
    function pullWeth(address to, uint256 amountWeth) external;

    function vat() external view returns (VatAbstract);
    function weth() external view returns (IWeth);
    function wethJoin() external view returns (GemJoinAbstract);
}
