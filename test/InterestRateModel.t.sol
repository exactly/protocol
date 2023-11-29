// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Market, InterestRateModel, UtilizationExceeded } from "../contracts/InterestRateModel.sol";
import { FixedLib } from "../contracts/utils/FixedLib.sol";
import { Auditor } from "../contracts/Auditor.sol";

contract InterestRateModelTest is Test {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint32;

  InterestRateModelHarness internal irm;

  function setUp() external {
    irm = new InterestRateModelHarness(
      Market(address(0)),
      1.3829e16,
      1.7429e16,
      1.1e18,
      7e17,
      2.5e18,
      1e18,
      15_000e16,
      0.2e18,
      0,
      0.5e18
    );
  }

  function testFixedBorrowRate() external {
    uint256 rate = irm.fixedRate(FixedLib.INTERVAL, 6, 0.5e18, 0, 0.5e18);
    assertEq(rate, 34290689491520350);
  }

  function testFloatingBorrowRate() external {
    uint256 rate = irm.floatingRate(0.5e18, 0.5e18);
    assertEq(rate, 42772870834956443);
  }

  function testRevertMaxUtilizationLowerThanWad() external {
    vm.expectRevert();
    new InterestRateModel(
      Market(address(0)),
      0.023e18,
      -0.0025e18,
      1e18 - 1,
      7e17,
      1.5e18,
      1.5e18,
      15_000e16,
      0.2e18,
      0,
      0.5e18
    );
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

  function testFuzzReferenceFixedRate(
    uint32 maturity,
    uint8 maxPools,
    uint64 uFixed,
    uint64 uFloating,
    uint64 uGlobal
  ) external {
    maxPools = uint8(_bound(maxPools, 1, 24));
    maturity = uint32(_bound(maturity, 1, maxPools) * FixedLib.INTERVAL);
    uFixed = uint64(_bound(uFixed, 0, 1.01e18));
    uFloating = uint64(_bound(uFloating, 0, 1.01e18 - uFixed));
    uGlobal = uint64(_bound(uGlobal, uFixed + uFloating, 1.01e18));

    uint256 refRate;
    if (uFixed > uGlobal || uFloating > uGlobal) {
      vm.expectRevert(UtilizationExceeded.selector);
    } else if (uGlobal >= 1e18) {
      refRate = irm.maxRate();
    } else {
      string[] memory ffi = new string[](2);
      ffi[0] = "scripts/irm-fixed.sh";
      ffi[1] = encodeHex(
        abi.encode(
          uFixed,
          uGlobal,
          irm.fixedNaturalUtilization(),
          irm.base(uFloating, uGlobal),
          irm.maturitySpeed(),
          irm.spreadFactor(),
          irm.timePreference(),
          maxPools,
          maturity,
          block.timestamp
        )
      );
      refRate = abi.decode(vm.ffi(ffi), (uint256));
      if (refRate > irm.maxRate()) refRate = irm.maxRate();
    }
    uint256 rate = irm.fixedRate(maturity, maxPools, uFixed, uFloating, uGlobal);

    assertLe(rate, irm.maxRate(), "rate > maxRate");
    assertApproxEqRel(rate, refRate, 1e12, "rate != expected");
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

  function testFuzzReferenceLegacyFixedRate(
    uint8 maturity,
    uint32 floatingAssets,
    uint32 floatingDebt,
    uint32[2] memory fixedBorrows,
    uint32[2] memory fixedDeposits,
    uint32 amount
  ) external {
    maturity = uint8(_bound(maturity, 0, 1));
    floatingDebt = uint32(_bound(floatingDebt, 0, floatingAssets));
    fixedBorrows[0] = uint32(_bound(fixedBorrows[0], 0, floatingAssets - floatingDebt));
    fixedBorrows[1] = uint32(_bound(fixedBorrows[1], 0, floatingAssets - floatingDebt - fixedBorrows[0]));
    fixedDeposits[0] = uint32(_bound(fixedDeposits[0], 0, fixedBorrows[0]));
    fixedDeposits[1] = uint32(_bound(fixedDeposits[1], 0, fixedBorrows[1]));
    amount = uint32(_bound(amount, 0, floatingAssets - floatingDebt - fixedBorrows[0] - fixedBorrows[1]));

    MockERC20 asset = new MockERC20("DAI", "DAI", 18);
    Market market = Market(
      address(new ERC1967Proxy(address(new Market(asset, Auditor(address(new MockAuditor())))), ""))
    );
    irm = new InterestRateModelHarness(
      market,
      6.8361e15,
      2.3785e16,
      1.1e18,
      7e17,
      2.5e18,
      2.5e18,
      15_000e16,
      0.2e18,
      0,
      0.5e18
    );
    market.initialize(uint8(fixedBorrows.length), 2e18, irm, 0.02e18 / uint256(1 days), 1e17, 0, 0.0046e18, 0.42e18);
    asset.mint(address(this), type(uint128).max);
    asset.approve(address(market), type(uint128).max);

    if (floatingAssets != 0) {
      market.deposit(floatingAssets, address(this));
    }
    vm.warp(FixedLib.INTERVAL / 2);
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

    uint256 fixedBorrowed = fixedBorrows[maturity] > fixedDeposits[maturity]
      ? fixedDeposits[maturity]
      : fixedBorrows[maturity];
    v.backupAmount = fixedBorrowed + amount > fixedDeposits[maturity]
      ? fixedBorrowed + amount - fixedDeposits[maturity]
      : 0;

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
}

contract MockAuditor {
  function checkBorrow(Market, address) external {} // solhint-disable-line no-empty-blocks

  // solhint-disable-next-line no-empty-blocks
  function checkShortfall(Market market, address account, uint256 amount) public view {}
}

contract InterestRateModelHarness is InterestRateModel {
  constructor(
    Market market_,
    uint256 curveA_,
    int256 curveB_,
    uint256 maxUtilization_,
    uint256 floatingNaturalUtilization_,
    int256 sigmoidSpeed_,
    int256 growthSpeed_,
    uint256 maxRate_,
    int256 spreadFactor_,
    int256 timePreference_,
    uint256 maturitySpeed_
  )
    InterestRateModel(
      market_,
      curveA_,
      curveB_,
      maxUtilization_,
      floatingNaturalUtilization_,
      sigmoidSpeed_,
      growthSpeed_,
      maxRate_,
      spreadFactor_,
      timePreference_,
      maturitySpeed_
    )
  {} //solhint-disable-line no-empty-blocks

  function base(uint256 uFloating, uint256 uGlobal) external view returns (uint256) {
    return baseRate(uFloating, uGlobal);
  }
}
