// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../utils/IWeth.sol";
import "../utils/IChai.sol";

import "dss-interfaces/src/dss/GemJoinAbstract.sol";
import "dss-interfaces/src/dss/DaiJoinAbstract.sol";
import "dss-interfaces/src/dss/VatAbstract.sol";
import "dss-interfaces/src/dss/DaiAbstract.sol";
import "dss-interfaces/src/dss/PotAbstract.sol";

interface ITreasury {
    function pushWeth(address to, uint256 amountWeth) external;
    function pullWeth(address to, uint256 amountWeth) external;

    function pushDai(address user, uint256 amountDai) external;
    function pullDai(address user, uint256 amountDai) external;

    function debt() external view returns(uint256);
    function savings() external view returns(uint256);

    function weth() external view returns (IWeth);
    function wethJoin() external view returns (GemJoinAbstract);
    function dai() external view returns (DaiAbstract);
    function daiJoin() external view returns (DaiJoinAbstract);
    function chai() external view returns (IChai);
    function pot() external view returns (PotAbstract);
    function vat() external view returns (VatAbstract);
}
