// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { InterestRateModel } from "../contracts/InterestRateModel.sol";
import { FixedLib } from "../contracts/utils/FixedLib.sol";

contract InterestRateModelTest is Test {
  using FixedPointMathLib for uint256;

  InterestRateModelHarness internal irm;

  function setUp() external {
    irm = new InterestRateModelHarness(0.023e18, -0.0025e18, 1.02e18, 0.023e18, -0.0025e18, 1.02e18);
  }

  function testMinFixedRate() external {
    uint256 borrowed = 10 ether;
    uint256 floatingAssetsAverage = 100 ether;
    (uint256 rate, uint256 utilization) = irm.minFixedRate(borrowed, 0, floatingAssetsAverage);
    assertEq(rate, 0.0225 ether);
    assertEq(utilization, 0.1 ether);
  }

  function testFixedBorrowRate() external {
    uint256 assets = 10 ether;
    uint256 floatingAssetsAverage = 100 ether;
    uint256 rate = irm.fixedBorrowRate(FixedLib.INTERVAL, assets, 0, 0, floatingAssetsAverage);
    assertEq(rate, 1628784207150172);
  }

  function testFloatingBorrowRate() external {
    uint256 floatingDebt = 50 ether;
    uint256 floatingAssets = 100 ether;
    uint256 rate = irm.floatingRate(floatingDebt.divWadDown(floatingAssets));
    assertEq(rate, 41730769230769230);
  }

  function testRevertFixedMaxUtilizationLowerThanWad() external {
    vm.expectRevert();
    new InterestRateModelHarness(0.023e18, -0.0025e18, 1e18 - 1, 0.023e18, -0.0025e18, 1.02e18);
  }

  function testRevertFloatingMaxUtilizationLowerThanWad() external {
    vm.expectRevert();
    new InterestRateModelHarness(0.023e18, -0.0025e18, 1.02e18, 0.023e18, -0.0025e18, 1e18 - 1);
  }

  function testFuzzReferenceRate(uint256 v0, uint64 delta) external {
    (uint256 rate, uint256 refRate) = irm.fixedRate(v0, delta);
    assertApproxEqAbs(rate, refRate, 3e3);
  }
}

contract InterestRateModelHarness is InterestRateModel, Test {
  constructor(
    uint256 fixedCurveA_,
    int256 fixedCurveB_,
    uint256 fixedMaxUtilization_,
    uint256 floatingCurveA_,
    int256 floatingCurveB_,
    uint256 floatingMaxUtilization_
  )
    InterestRateModel(
      fixedCurveA_,
      fixedCurveB_,
      fixedMaxUtilization_,
      floatingCurveA_,
      floatingCurveB_,
      floatingMaxUtilization_
    )
  {} // solhint-disable-line no-empty-blocks

  function fixedRate(uint256 v0, uint64 delta) public returns (uint256 rate, uint256 refRate) {
    uint256 u0 = v0 % 1e18;
    uint256 u1 = u0 + (delta % (floatingMaxUtilization - u0));

    rate = fixedRate(u0, u1);

    string[] memory ffi = new string[](2);
    ffi[0] = "scripts/irm.sh";
    ffi[1] = encodeHex(abi.encode(u0, u1, floatingCurveA, floatingCurveB, floatingMaxUtilization));
    refRate = abi.decode(vm.ffi(ffi), (uint256));
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
