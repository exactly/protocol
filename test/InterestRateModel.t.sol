// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Market, InterestRateModel, UtilizationExceeded } from "../contracts/InterestRateModel.sol";
import { FixedLib } from "../contracts/utils/FixedLib.sol";

contract InterestRateModelTest is Test {
  using FixedPointMathLib for uint256;

  InterestRateModel internal irm;

  function setUp() external {
    irm = new InterestRateModel(Market(address(0)), 1.3829e16, 1.7429e16, 1.1e18, 7e17, 2.5e18, 1e18, 15_000e16);
  }

  function testMinFixedRate() external {
    uint256 borrowed = 10 ether;
    uint256 floatingAssetsAverage = 100 ether;
    (uint256 rate, uint256 utilization) = irm.minFixedRate(borrowed, 0, floatingAssetsAverage);
    assertEq(rate, 0.031258 ether);
    assertEq(utilization, 0.1 ether);
  }

  function testFixedBorrowRate() external {
    uint256 assets = 10 ether;
    uint256 floatingAssetsAverage = 100 ether;
    uint256 rate = irm.fixedBorrowRate(FixedLib.INTERVAL, assets, 0, 0, floatingAssetsAverage);
    assertEq(rate, 2348120819583400);
  }

  function testFloatingBorrowRate() external {
    uint256 rate = irm.floatingRate(0.5e18, 0.5e18);
    assertEq(rate, 42772870834956443);
  }

  function testRevertMaxUtilizationLowerThanWad() external {
    vm.expectRevert();
    new InterestRateModel(Market(address(0)), 0.023e18, -0.0025e18, 1e18 - 1, 7e17, 1.5e18, 1.5e18, 15_000e16);
  }

  function testFuzzReferenceFloatingRate(uint64 uFloating, uint64 uGlobal) external {
    uFloating = uint64(_bound(uFloating, 0, 1e18));
    uGlobal = uint64(_bound(uGlobal, 0, 1e18));

    uint256 refRate;
    if (uFloating > uGlobal) {
      vm.expectRevert(UtilizationExceeded.selector);
    } else if (uGlobal >= 1e18) {
      refRate = irm.maxRate();
    } else {
      string[] memory ffi = new string[](2);
      ffi[0] = "scripts/irm-floating.sh";
      ffi[1] = encodeHex(
        abi.encode(
          uFloating,
          uGlobal,
          irm.floatingNaturalUtilization(),
          irm.floatingCurveA(),
          irm.floatingCurveB(),
          irm.floatingMaxUtilization(),
          irm.sigmoidSpeed(),
          irm.growthSpeed()
        )
      );
      refRate = abi.decode(vm.ffi(ffi), (uint256));
      if (refRate > irm.maxRate()) refRate = irm.maxRate();
    }
    uint256 rate = irm.floatingRate(uFloating, uGlobal);

    assertApproxEqRel(rate, refRate, 1e4, "rate != expected");
    assertLe(rate, irm.maxRate(), "rate > maxRate");
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
