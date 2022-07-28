// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";

contract InterestRateModelTest is
  Test,
  InterestRateModel(
    InterestRateModel.Curve({ a: 3.75e16, b: 0.75e16, maxUtilization: 3e18 }),
    2e18,
    InterestRateModel.Curve({ a: 3.75e16, b: 0.75e16, maxUtilization: 3e18 }),
    2e18
  )
{
  using FixedPointMathLib for uint256;

  function testFixedBorrowRate() external {
    uint256 assets = 10 ether;
    uint256 floatingAssetsAverage = 100 ether;
    uint256 rate = this.fixedBorrowRate(FixedLib.INTERVAL, assets, 0, 0, floatingAssetsAverage);
    assertEq(rate, 1567705037744728);
  }

  function testFloatingBorrowRate() external {
    uint256 smartPoolFloatingBorrows = 50 ether;
    uint256 floatingAssets = 100 ether;
    uint256 spCurrentUtilization = smartPoolFloatingBorrows.divWadDown(
      floatingAssets.divWadDown(floatingFullUtilization)
    );
    uint256 rate = this.floatingBorrowRate(0, spCurrentUtilization);
    assertEq(rate, 22704941554056164);
  }

  function testFloatingBorrowRateUsingMinMaxUtilizations() external {
    uint256 utilizationBefore = 0.5e18;
    uint256 utilizationAfter = 1.5e18;
    uint256 rate = this.floatingBorrowRate(utilizationBefore, utilizationAfter);

    utilizationBefore = 1.5e18;
    utilizationAfter = 0.5e18;
    uint256 newRate = this.floatingBorrowRate(utilizationBefore, utilizationAfter);

    assertEq(rate, newRate);
  }

  function testReferenceFloatingRate(uint256 v0, uint64 delta) external {
    Curve memory params = floatingCurve;
    uint256 u0 = v0 % floatingFullUtilization;
    uint256 u1 = u0 + (delta % (params.maxUtilization - u0));

    string[] memory ffi = new string[](2);
    ffi[0] = "scripts/irm.sh";
    ffi[1] = encodeHex(abi.encode(u0, u1, params.a, params.b, params.maxUtilization));
    uint256 refRate = abi.decode(vm.ffi(ffi), (uint256));

    assertApproxEqRel(floatingRate(u0, u1), refRate, 1.5e9);
  }

  function testReferenceFixedRate(uint256 v0, uint64 delta) external {
    Curve memory params = fixedCurve;
    uint256 u0 = v0 % fixedFullUtilization;
    uint256 u1 = u0 + (delta % (params.maxUtilization - u0));

    string[] memory ffi = new string[](2);
    ffi[0] = "scripts/irm.sh";
    ffi[1] = encodeHex(abi.encode(u0, u1, params.a, params.b, params.maxUtilization));
    uint256 refRate = abi.decode(vm.ffi(ffi), (uint256));

    assertApproxEqRel(fixedRate(u0, u1), refRate, 1.5e9);
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
