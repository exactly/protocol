// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";

contract InterestRateModelTest is
  Test,
  InterestRateModel(0.023e18, -0.0025e18, 1.02e18, 0.023e18, -0.0025e18, 1.02e18)
{
  using FixedPointMathLib for uint256;

  function testFixedBorrowRate() external {
    uint256 assets = 10 ether;
    uint256 floatingAssetsAverage = 100 ether;
    uint256 rate = this.fixedBorrowRate(FixedLib.INTERVAL, assets, 0, 0, floatingAssetsAverage);
    assertEq(rate, 1628784207150172);
  }

  function testFloatingBorrowRate() external {
    uint256 smartPoolFloatingBorrows = 50 ether;
    uint256 floatingAssets = 100 ether;
    uint256 spCurrentUtilization = smartPoolFloatingBorrows.divWadDown(floatingAssets);
    uint256 rate = this.floatingBorrowRate(0, spCurrentUtilization);
    assertEq(rate, 28491538356330811);
  }

  function testFloatingBorrowRateUsingMinMaxUtilizations() external {
    uint256 utilizationBefore = 0.5e18;
    uint256 utilizationAfter = 0.9e18;
    uint256 rate = this.floatingBorrowRate(utilizationBefore, utilizationAfter);

    utilizationBefore = 0.9e18;
    utilizationAfter = 0.5e18;
    uint256 newRate = this.floatingBorrowRate(utilizationBefore, utilizationAfter);

    assertEq(rate, newRate);
  }

  function testReferenceFloatingRate(uint256 v0, uint64 delta) external {
    uint256 u0 = v0 % 1e18;
    uint256 u1 = u0 + (delta % (floatingMaxUtilization - u0));

    string[] memory ffi = new string[](2);
    ffi[0] = "scripts/irm.sh";
    ffi[1] = encodeHex(abi.encode(u0, u1, floatingCurveA, floatingCurveB, floatingMaxUtilization));
    uint256 refRate = abi.decode(vm.ffi(ffi), (uint256));

    assertApproxEqAbs(floatingRate(u0, u1), refRate, 3e3);
  }

  function encodeHex(bytes memory raw) internal pure returns (string memory) {
    bytes16 symbols = "0123456789abcdef";
    bytes memory buffer = new bytes(2 * raw.length + 2);
    buffer[0] = "0";
    buffer[1] = "x";
    for (uint256 i = 0; i < raw.length; i++) {
      buffer[2 * i + 2] = symbols[uint8(raw[i]) >> 4];
      buffer[2 * i + 3] = symbols[uint8(raw[i]) & 0xf];
    }
    return string(buffer);
  }
}
