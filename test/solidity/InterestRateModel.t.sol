// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { TSUtils } from "../../contracts/utils/TSUtils.sol";

contract InterestRateModelTest is
  Test,
  InterestRateModel(3.75e16, 0.75e16, 3e18, 2e18, 3.75e16, 0.75e16, 3e18, 2e18, 0)
{
  using FixedPointMathLib for uint256;

  function testGetRateToBorrow() external {
    uint256 assets = 10 ether;
    uint256 smartPoolAssetsAverage = 100 ether;
    uint256 rate = this.getRateToBorrow(TSUtils.INTERVAL, 1, assets, 0, 0, smartPoolAssetsAverage);
    assertEq(rate, 1567705037744728);
  }

  function testGetFlexibleBorrowRate() external {
    uint256 smartPoolFlexibleBorrows = 50 ether;
    uint256 smartPoolAssets = 100 ether;
    uint256 spCurrentUtilization = smartPoolFlexibleBorrows.divWadDown(
      smartPoolAssets.divWadDown(this.flexibleFullUtilization())
    );
    uint256 rate = this.getFlexibleBorrowRate(0, spCurrentUtilization);
    assertEq(rate, 22704941554056164);
  }

  function testGetFlexibleBorrowRateUsingMinMaxUtilizations() external {
    uint256 utilizationBefore = 0.5e18;
    uint256 utilizationAfter = 1.5e18;
    uint256 rate = this.getFlexibleBorrowRate(utilizationBefore, utilizationAfter);

    utilizationBefore = 1.5e18;
    utilizationAfter = 0.5e18;
    uint256 newRate = this.getFlexibleBorrowRate(utilizationBefore, utilizationAfter);

    assertEq(rate, newRate);
  }

  event Debug(string test, uint256 testVar);

  function testReferenceFlexibleRate(uint256 v0, uint64 delta) external {
    uint256 u0 = v0 % flexibleFullUtilization;
    uint256 u1 = u0 + (delta % (flexibleMaxUtilization - u0));

    string[] memory ffi = new string[](2);
    ffi[0] = "ffi/irm";
    ffi[1] = encodeHex(abi.encode(u0, u1, flexibleCurveA, flexibleCurveB, flexibleMaxUtilization));
    uint256 refRate = abi.decode(vm.ffi(ffi), (uint256));

    assertApproxEqRel(flexibleRate(u0, u1), refRate, 1.5e9);
  }

  function testReferenceFixedRate(uint256 v0, uint64 delta) external {
    uint256 u0 = v0 % fixedFullUtilization;
    uint256 u1 = u0 + (delta % (fixedMaxUtilization - u0));

    string[] memory ffi = new string[](2);
    ffi[0] = "ffi/irm";
    ffi[1] = encodeHex(abi.encode(u0, u1, fixedCurveA, fixedCurveB, fixedMaxUtilization));
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
