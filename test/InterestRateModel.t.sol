// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17; // solhint-disable-line one-contract-per-file

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Market, InterestRateModel, Parameters } from "../contracts/InterestRateModel.sol";
import { FixedLib } from "../contracts/utils/FixedLib.sol";
import { Auditor } from "../contracts/Auditor.sol";

contract InterestRateModelTest is Test {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;

  InterestRateModelHarness internal irm;

  function testFixedBorrowRate() external {
    assertEq(deployDefault().fixedRate(FixedLib.INTERVAL, 6, 0.75e18, 0, 0.75e18), 63726888252924763);
  }

  function testFloatingBorrowRate() external {
    assertEq(deployDefault().floatingRate(0.75e18, 0.75e18), 80000000000000000);
  }

  function testRevertMaxUtilizationLowerThanWad() external {
    vm.expectRevert();
    new InterestRateModel(
      Parameters({
        minRate: 3.5e16,
        naturalRate: 8e16,
        maxUtilization: 1e18 - 1,
        naturalUtilization: 0.75e18,
        growthSpeed: 1.1e18,
        sigmoidSpeed: 2.5e18,
        spreadFactor: 0.2e18,
        maturitySpeed: 0.5e18,
        timePreference: 0.01e18,
        fixedAllocation: 0.6e18,
        maxRate: 15_000e16
      }),
      Market(address(0))
    );
  }

  function testFuzzReferenceRateFloating(uint256 uFloating, uint256 uGlobal, FloatingParameters memory p) external {
    uFloating = _bound(uFloating, 0, 1.01e18);
    uGlobal = _bound(uGlobal, uFloating, 1.01e18);
    p.maxUtilization = _bound(p.maxUtilization, 1.01e18 + 1, 2e18);
    p.naturalUtilization = _bound(p.naturalUtilization, 0.4e18, 0.9e18);
    p.growthSpeed = _bound(p.growthSpeed, 1, 5e18);
    (p.minRate, p.naturalRate) = boundCurve(p.minRate, p.naturalRate, p.naturalUtilization, p.growthSpeed);
    p.sigmoidSpeed = _bound(p.sigmoidSpeed, 1, 10e18);
    p.maxRate = _bound(p.maxRate, 100e16, 10_000e16);

    irm = new InterestRateModelHarness(
      Parameters({
        minRate: p.minRate,
        naturalRate: p.naturalRate,
        maxUtilization: p.maxUtilization,
        naturalUtilization: p.naturalUtilization,
        growthSpeed: p.growthSpeed,
        sigmoidSpeed: p.sigmoidSpeed,
        spreadFactor: 0.2e18,
        maturitySpeed: 0.5e18,
        timePreference: 0.01e18,
        fixedAllocation: 0.6e18,
        maxRate: p.maxRate
      }),
      Market(address(0))
    );

    string[] memory ffi = new string[](2);
    ffi[0] = "scripts/irm-floating.sh";
    ffi[1] = encodeHex(
      abi.encode(
        irm.floatingCurveA(),
        irm.floatingCurveB(),
        p.maxUtilization,
        p.naturalUtilization,
        p.growthSpeed,
        p.sigmoidSpeed,
        p.maxRate,
        uFloating,
        uGlobal
      )
    );
    uint256 refRate = abi.decode(vm.ffi(ffi), (uint256));
    uint256 rate = irm.floatingRate(uFloating, uGlobal);

    assertLe(rate, p.maxRate, "rate > maxRate");
    assertApproxEqRel(rate, refRate, 0.002e16, "rate != refRate");
  }

  function testFuzzReferenceRateFixed(
    uint256 timestamp,
    uint256 maturity,
    uint256 maxPools,
    uint256 uFixed,
    uint256 uFloating,
    uint256 uGlobal,
    Parameters memory p
  ) external {
    timestamp = _bound(timestamp, 0, 2 * FixedLib.INTERVAL);
    vm.warp(timestamp);

    maxPools = _bound(maxPools, 6, 24);
    maturity = _bound(maturity, 1, maxPools) * FixedLib.INTERVAL + timestamp - (timestamp % FixedLib.INTERVAL);
    uFixed = _bound(uFixed, 0, 1.01e18);
    uFloating = _bound(uFloating, 0, 1.01e18 - uFixed);
    uGlobal = _bound(uGlobal, uFixed + uFloating, 1.01e18);
    p.maxUtilization = _bound(p.maxUtilization, 1.01e18 + 1, 2e18);
    p.naturalUtilization = _bound(p.naturalUtilization, 0.4e18, 0.9e18);
    p.growthSpeed = _bound(p.growthSpeed, 1, 5e18);
    (p.minRate, p.naturalRate) = boundCurve(p.naturalRate, p.minRate, p.naturalUtilization, p.growthSpeed);
    p.sigmoidSpeed = _bound(p.sigmoidSpeed, 1, 10e18);
    p.spreadFactor = _bound(p.spreadFactor, 1, 0.5e18);
    p.maturitySpeed = _bound(p.maturitySpeed, 1, 5e18);
    p.timePreference = _bound(p.timePreference, -0.1e18, 0.1e18);
    p.fixedAllocation = _bound(p.fixedAllocation, 0.01e18, 1e18);
    p.maxRate = _bound(p.maxRate, 100e16, 10_000e16);

    irm = new InterestRateModelHarness(
      Parameters({
        minRate: p.minRate,
        naturalRate: p.naturalRate,
        maxUtilization: p.maxUtilization,
        naturalUtilization: p.naturalUtilization,
        growthSpeed: p.growthSpeed,
        sigmoidSpeed: p.sigmoidSpeed,
        spreadFactor: p.spreadFactor,
        maturitySpeed: p.maturitySpeed,
        timePreference: p.timePreference,
        fixedAllocation: p.fixedAllocation,
        maxRate: p.maxRate
      }),
      Market(address(0))
    );

    string[] memory ffi = new string[](2);
    ffi[0] = "scripts/irm-fixed.sh";
    ffi[1] = encodeHex(
      abi.encode(
        irm.base(uFloating, uGlobal),
        p.spreadFactor,
        p.maturitySpeed,
        p.timePreference,
        p.fixedAllocation,
        p.maxRate,
        maturity,
        maxPools,
        uFixed,
        uGlobal,
        block.timestamp
      )
    );
    uint256 refRate = abi.decode(vm.ffi(ffi), (uint256));
    uint256 rate = irm.fixedRate(maturity, maxPools, uFixed, uFloating, uGlobal);

    assertLe(rate, p.maxRate, "rate > maxRate");
    assertApproxEqRel(rate, refRate, 0.00000002e16, "rate != refRate");
  }

  function testFuzzReferenceLegacyRateFixed(
    uint32 floatingAssets,
    uint256 floatingDebt,
    uint256[2] memory fixedBorrows,
    uint256[2] memory fixedDeposits,
    uint256 timestamp,
    uint256 maturity,
    uint256 amount
  ) external {
    floatingDebt = _bound(floatingDebt, 0, floatingAssets);
    fixedBorrows[0] = _bound(fixedBorrows[0], 0, floatingAssets - floatingDebt);
    fixedBorrows[1] = _bound(fixedBorrows[1], 0, floatingAssets - floatingDebt - fixedBorrows[0]);
    fixedDeposits[0] = _bound(fixedDeposits[0], 0, fixedBorrows[0]);
    fixedDeposits[1] = _bound(fixedDeposits[1], 0, fixedBorrows[1]);
    timestamp = _bound(timestamp, 2, FixedLib.INTERVAL - 1);
    maturity = _bound(maturity, 0, 1);
    amount = _bound(amount, 0, floatingAssets - floatingDebt - fixedBorrows[0] - fixedBorrows[1]);

    MockERC20 asset = new MockERC20("", "", 18);
    Market market = Market(
      address(new ERC1967Proxy(address(new Market(asset, Auditor(address(new MockAuditor())))), ""))
    );
    irm = new InterestRateModelHarness(
      Parameters({
        minRate: 3.5e16,
        naturalRate: 8e16,
        maxUtilization: 1.3e18,
        naturalUtilization: 0.75e18,
        growthSpeed: 1.1e18,
        sigmoidSpeed: 2.5e18,
        spreadFactor: 0.2e18,
        maturitySpeed: 0.5e18,
        timePreference: 0.01e18,
        fixedAllocation: 0.6e18,
        maxRate: 15_000e16
      }),
      market
    );
    market.initialize(2, 2e18, irm, 2e16 / uint256(1 days), 1e17, 0, type(uint128).max, type(uint128).max);
    asset.mint(address(this), type(uint128).max);
    asset.approve(address(market), type(uint128).max);
    if (floatingAssets != 0) market.deposit(floatingAssets, address(this));
    vm.warp(timestamp);
    market.borrow(floatingDebt, address(this), address(this));

    Vars memory v;
    v.backupBorrowed = 0;
    for (uint256 i = 0; i < fixedBorrows.length; i++) {
      if (fixedBorrows[i] != 0) {
        market.borrowAtMaturity(
          (i + 1) * FixedLib.INTERVAL,
          fixedBorrows[i],
          type(uint256).max,
          address(this),
          address(this)
        );
      }
      if (fixedDeposits[i] != 0) {
        market.depositAtMaturity((i + 1) * FixedLib.INTERVAL, fixedDeposits[i], 0, address(this));
      }
      v.backupBorrowed += fixedBorrows[i] > fixedDeposits[i] ? fixedBorrows[i] - fixedDeposits[i] : 0;
    }

    {
      uint256 fixedBorrowed = fixedBorrows[maturity] > fixedDeposits[maturity]
        ? fixedDeposits[maturity]
        : fixedBorrows[maturity];
      v.backupAmount = fixedBorrowed + amount > fixedDeposits[maturity]
        ? fixedBorrowed + amount - fixedDeposits[maturity]
        : 0;
    }

    v.uFixed = fixedUtilization(fixedDeposits[maturity], fixedBorrows[maturity] + amount, floatingAssets);
    v.uFloating = floatingAssets > 0 ? floatingDebt.divWadUp(floatingAssets) : 0;
    v.uGlobal = globalUtilization(floatingAssets, floatingDebt, v.backupBorrowed + v.backupAmount);

    v.refRate = irm.fixedRate(
      (maturity + 1) * FixedLib.INTERVAL,
      fixedBorrows.length,
      v.uFixed,
      v.uFloating,
      v.uGlobal
    );

    v.rate = irm.fixedBorrowRate(
      (maturity + 1) * FixedLib.INTERVAL,
      amount,
      fixedBorrows[maturity],
      fixedDeposits[maturity],
      floatingAssets
    );

    assertEq(v.rate, v.refRate, "rate != refRate");
  }

  function boundCurve(
    uint256 minRate,
    uint256 naturalRate,
    uint256 naturalUtilization,
    uint256 growthSpeed
  ) internal pure returns (uint256, uint256) {
    minRate = _bound(minRate, 1e16, 10e16);
    uint256 minNaturalRate = minRate.mulWadUp(
      uint256(((-int256(growthSpeed) * (1e18 - int256(naturalUtilization / 2)).lnWad()) / 1e18).expWad())
    ) + 50;
    naturalRate = _bound(
      naturalRate,
      Math.max(minNaturalRate, minRate.mulWadUp(1.2e18)),
      Math.max(minNaturalRate, minRate.mulWadUp(2e18))
    );
    return (minRate, naturalRate);
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

  function fixedUtilization(
    uint256 supplied,
    uint256 borrowed,
    uint256 floatingAssets
  ) internal pure returns (uint256) {
    return floatingAssets > 0 && borrowed > supplied ? (borrowed - supplied).divWadUp(floatingAssets) : 0;
  }

  function globalUtilization(
    uint256 floatingAssets,
    uint256 floatingDebt,
    uint256 backupBorrowed
  ) internal pure returns (uint256) {
    return floatingAssets > 0 ? 1e18 - (floatingAssets - floatingDebt - backupBorrowed).divWadDown(floatingAssets) : 0;
  }

  function floatingUtilization(uint256 floatingAssets, uint256 floatingDebt) internal pure returns (uint256) {
    return floatingAssets > 0 ? floatingDebt.divWadUp(floatingAssets) : 0;
  }

  function deployDefault() internal returns (InterestRateModelHarness) {
    return
      new InterestRateModelHarness(
        Parameters({
          minRate: 3.5e16,
          naturalRate: 8e16,
          maxUtilization: 1.3e18,
          naturalUtilization: 0.75e18,
          growthSpeed: 1.1e18,
          sigmoidSpeed: 2.5e18,
          spreadFactor: 0.2e18,
          maturitySpeed: 0.5e18,
          timePreference: 0.01e18,
          fixedAllocation: 0.6e18,
          maxRate: 15_000e16
        }),
        Market(address(0))
      );
  }
}

contract MockAuditor {
  function checkBorrow(Market, address) external {} // solhint-disable-line no-empty-blocks

  // solhint-disable-next-line no-empty-blocks
  function checkShortfall(Market market, address account, uint256 amount) public view {}
}

contract InterestRateModelHarness is InterestRateModel {
  // solhint-disable-next-line no-empty-blocks
  constructor(Parameters memory p_, Market market_) InterestRateModel(p_, market_) {}

  function base(uint256 uFloating, uint256 uGlobal) external view returns (uint256) {
    return baseRate(uFloating, uGlobal);
  }
}

struct FloatingParameters {
  uint256 minRate;
  uint256 naturalRate;
  uint256 maxUtilization;
  uint256 naturalUtilization;
  uint256 growthSpeed;
  uint256 sigmoidSpeed;
  uint256 maxRate;
}

struct Vars {
  uint256 rate;
  uint256 refRate;
  uint256 uFixed;
  uint256 uFloating;
  uint256 uGlobal;
  uint256 backupBorrowed;
  uint256 backupAmount;
}
