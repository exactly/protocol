// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ForkTest } from "./Fork.t.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { DebtPreviewer, IUniswapQuoter } from "../../contracts/periphery/DebtPreviewer.sol";
import {
  DebtManager,
  Auditor,
  Market,
  ERC20,
  IPermit2,
  IBalancerVault
} from "../../contracts/periphery/DebtManager.sol";

contract DebtPreviewerTest is ForkTest {
  using FixedPointMathLib for uint256;

  address internal constant ALICE = address(0x420);
  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
  DebtPreviewer internal debtPreviewer;
  DebtManager internal debtManager;
  Market internal marketOP;
  Market internal marketWETH;
  Market internal marketUSDC;
  Market internal marketwstETH;
  ERC20 internal weth;
  ERC20 internal usdc;
  ERC20 internal wstETH;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 99_811_375);
    Auditor auditor = Auditor(deployment("Auditor"));
    IPermit2 permit2 = IPermit2(deployment("Permit2"));
    marketOP = Market(deployment("MarketOP"));
    marketWETH = Market(deployment("MarketWETH"));
    marketUSDC = Market(deployment("MarketUSDC"));
    marketwstETH = Market(deployment("MarketwstETH"));
    weth = ERC20(deployment("WETH"));
    usdc = ERC20(deployment("USDC"));
    wstETH = ERC20(deployment("wstETH"));
    debtManager = DebtManager(
      address(
        new ERC1967Proxy(
          address(
            new DebtManager(
              auditor,
              permit2,
              IBalancerVault(deployment("BalancerVault")),
              deployment("UniswapV3Factory")
            )
          ),
          abi.encodeCall(DebtManager.initialize, ())
        )
      )
    );

    DebtPreviewer.Pool[] memory pools = new DebtPreviewer.Pool[](4);
    pools[0] = DebtPreviewer.Pool(address(weth), address(usdc));
    pools[1] = DebtPreviewer.Pool(address(usdc), address(weth));
    pools[2] = DebtPreviewer.Pool(address(wstETH), address(weth));
    pools[3] = DebtPreviewer.Pool(address(weth), address(wstETH));
    uint24[] memory fees = new uint24[](4);
    fees[0] = 500;
    fees[1] = 500;
    fees[2] = 500;
    fees[3] = 500;

    debtPreviewer = DebtPreviewer(
      address(
        new ERC1967Proxy(
          address(new DebtPreviewer(debtManager, IUniswapQuoter(deployment("UniswapV3Quoter")), pools, fees)),
          abi.encodeCall(DebtPreviewer.initialize, ())
        )
      )
    );

    deal(address(usdc), address(this), 22_000_000e6);
    deal(address(weth), address(this), 1_000e18);
    deal(address(wstETH), address(this), 1_000e18);
    marketUSDC.approve(address(debtManager), type(uint256).max);
    marketWETH.approve(address(debtManager), type(uint256).max);
    marketwstETH.approve(address(debtManager), type(uint256).max);
    weth.approve(address(marketWETH), type(uint256).max);
    usdc.approve(address(marketUSDC), type(uint256).max);
    usdc.approve(address(debtManager), type(uint256).max);
    wstETH.approve(address(debtManager), type(uint256).max);
    weth.approve(address(debtManager), type(uint256).max);
    debtManager.auditor().enterMarket(marketUSDC);
  }

  function testAvailableLiquidity() external {
    DebtPreviewer.AvailableAsset[] memory availableAssets = debtPreviewer.availableLiquidity();
    Market[] memory markets = debtManager.auditor().allMarkets();
    assertEq(availableAssets.length, markets.length);
    assertEq(address(availableAssets[1].asset), address(usdc));
    assertEq(availableAssets[1].liquidity, usdc.balanceOf(address(debtManager.balancerVault())));
  }

  function testUniswapV3PoolInfo() external {
    (address token0, address token1, uint256 sqrtPriceX96) = debtPreviewer.uniswapV3PoolInfo(
      address(usdc),
      address(weth),
      500
    );

    assertApproxEqAbs((sqrtPriceX96 * sqrtPriceX96 * 1e18) >> (96 * 2), 1810e6, 1e6);
    assertEq(token0, address(weth));
    assertEq(token1, address(usdc));
  }

  function testPreviewInputSwap() external {
    assertEq(debtPreviewer.previewInputSwap(address(weth), address(usdc), 1e18, 500), 1809407986);
    assertEq(debtPreviewer.previewInputSwap(address(weth), address(usdc), 100e18, 500), 180326534411);
    assertEq(debtPreviewer.previewInputSwap(address(usdc), address(weth), 1_800e6, 500), 993744547172020639);
    assertEq(debtPreviewer.previewInputSwap(address(usdc), address(weth), 100_000e6, 500), 55114623226316151402);
    assertEq(debtPreviewer.previewInputSwap(address(wstETH), address(weth), 1e18, 500), 1124234920941937964);
  }

  function testSetPoolFee() external {
    debtPreviewer.setPoolFee(DebtPreviewer.Pool(address(wstETH), address(usdc)), 500);
  }

  function testSetPoolFeeFromAnotherAccount() external {
    vm.prank(ALICE);
    vm.expectRevert(bytes(""));
    debtPreviewer.setPoolFee(DebtPreviewer.Pool(address(wstETH), address(usdc)), 500);
  }

  function testPreviewLeverage() external {
    uint256 ratio = 2e18;
    uint256 principal = 10_000e6;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, principal, ratio, MIN_SQRT_RATIO + 1);

    DebtPreviewer.Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this));
    (uint256 collateralAdjustFactor, , , , ) = debtManager.auditor().markets(marketUSDC);
    (uint256 debtAdjustFactor, , , , ) = debtManager.auditor().markets(marketWETH);
    assertApproxEqAbs(leverage.principal, principal, 2e18);
    assertApproxEqAbs(leverage.collateral, principal.mulWadDown(ratio), 1);
    assertApproxEqAbs(leverage.ratio, ratio, 0.0003e18);
    assertApproxEqAbs(
      leverage.maxRatio,
      uint256(1e18).divWadDown(1e18 - collateralAdjustFactor.mulWadDown(debtAdjustFactor)),
      0.000000004e18
    );
  }

  function testPreviewEmptyLeverage() external {
    DebtPreviewer.Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this));
    (uint256 collateralAdjustFactor, , , , ) = debtManager.auditor().markets(marketUSDC);
    (uint256 debtAdjustFactor, , , , ) = debtManager.auditor().markets(marketWETH);

    assertEq(leverage.principal, 0);
    assertEq(leverage.collateral, 0);
    assertEq(leverage.debt, 0);
    assertEq(leverage.ratio, 1e18);
    assertEq(leverage.maxRatio, uint256(1e18).divWadDown(1e18 - collateralAdjustFactor.mulWadDown(debtAdjustFactor)));
  }

  function testPreviewLeverageMaxRatioSingleCollateralAndDebt() external {
    uint256 ratio = 2e18;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 10_000e6, ratio, MIN_SQRT_RATIO + 1);

    DebtPreviewer.Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this));
    ratio = leverage.maxRatio - 0.01e18;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, ratio, MIN_SQRT_RATIO + 1);
    (uint256 coll, uint256 debt) = debtManager.auditor().accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageUSDCMaxRatioMultipleCollateralAndDebt() external {
    marketUSDC.deposit(10_000e6, address(this));
    debtManager.auditor().enterMarket(marketUSDC);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketWETH.borrow(0.5e18, address(this), address(this));

    DebtPreviewer.Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this));
    uint256 ratio = leverage.maxRatio - 0.005e18;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, ratio, MIN_SQRT_RATIO + 1);
    (uint256 coll, uint256 debt) = debtManager.auditor().accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageWETHMaxRatioMultipleCollateralAndDebt() external {
    marketWETH.deposit(5e18, address(this));
    debtManager.auditor().enterMarket(marketWETH);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketUSDC.borrow(1_000e6, address(this), address(this));

    DebtPreviewer.Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketUSDC, address(this));
    uint256 ratio = leverage.maxRatio - 0.01e18;
    debtManager.crossLeverage(marketWETH, marketUSDC, 500, 0, ratio, MAX_SQRT_RATIO - 1);
    (uint256 coll, uint256 debt) = debtManager.auditor().accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageMaxRatioSameAssetUSDCBorrow() external {
    marketUSDC.deposit(10_000e6, address(this));
    debtManager.auditor().enterMarket(marketUSDC);
    marketUSDC.borrow(2_000e6, address(this), address(this));

    DebtPreviewer.Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this));
    uint256 ratio = leverage.maxRatio - 0.005e18;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, ratio, MIN_SQRT_RATIO + 1);
    (uint256 coll, uint256 debt) = debtManager.auditor().accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageMaxRatioSameAssetWETHBorrow() external {
    marketWETH.deposit(5e18, address(this));
    debtManager.auditor().enterMarket(marketWETH);
    marketWETH.borrow(1e18, address(this), address(this));

    DebtPreviewer.Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketUSDC, address(this));
    uint256 ratio = leverage.maxRatio - 0.015e18;
    debtManager.crossLeverage(marketWETH, marketUSDC, 500, 0, ratio, MAX_SQRT_RATIO - 1);
    (uint256 coll, uint256 debt) = debtManager.auditor().accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }
}
