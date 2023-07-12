// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ForkTest, stdError } from "./Fork.t.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
  DebtPreviewer,
  IUniswapQuoter,
  Leverage,
  Limit,
  Pool,
  InvalidPreview
} from "../../contracts/periphery/DebtPreviewer.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";
import {
  DebtManager,
  Market,
  ERC20,
  IPermit2,
  IPriceFeed,
  IBalancerVault
} from "../../contracts/periphery/DebtManager.sol";
import { Auditor, InsufficientAccountLiquidity } from "../../contracts/Auditor.sol";

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
  Auditor internal auditor;
  uint256 internal maturity;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 99_811_375);
    auditor = Auditor(deployment("Auditor"));
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

    Pool[] memory pools = new Pool[](2);
    pools[0] = Pool(address(weth), address(usdc));
    pools[1] = Pool(address(weth), address(wstETH));
    uint24[] memory fees = new uint24[](2);
    fees[0] = 500;
    fees[1] = 500;

    debtPreviewer = DebtPreviewer(
      address(
        new ERC1967Proxy(
          address(new DebtPreviewer(debtManager, IUniswapQuoter(deployment("UniswapV3Quoter")))),
          abi.encodeCall(DebtPreviewer.initialize, (pools, fees))
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
    wstETH.approve(address(marketwstETH), type(uint256).max);
    weth.approve(address(debtManager), type(uint256).max);
    auditor.enterMarket(marketUSDC);
    maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
  }

  function testPreviewInputSwap() external {
    assertEq(debtPreviewer.previewInputSwap(address(weth), address(usdc), 1e18, 500), 1809407986);
    assertEq(debtPreviewer.previewInputSwap(address(weth), address(usdc), 100e18, 500), 180326534411);
    assertEq(debtPreviewer.previewInputSwap(address(usdc), address(weth), 1_800e6, 500), 993744547172020639);
    assertEq(debtPreviewer.previewInputSwap(address(usdc), address(weth), 100_000e6, 500), 55114623226316151402);
    assertEq(debtPreviewer.previewInputSwap(address(wstETH), address(weth), 1e18, 500), 1124234920941937964);
  }

  function testSetPoolFee() external {
    debtPreviewer.setPoolFee(Pool(address(wstETH), address(usdc)), 500);
  }

  function testSetPoolFeeFromAnotherAccount() external {
    vm.prank(ALICE);
    vm.expectRevert(bytes(""));
    debtPreviewer.setPoolFee(Pool(address(wstETH), address(usdc)), 500);
  }

  function testPreviewLeverage() external {
    uint256 ratio = 2e18;
    uint256 principal = 10_000e6;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, principal, ratio, MIN_SQRT_RATIO + 1);

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    (uint256 collateralAdjustFactor, , , , ) = auditor.markets(marketUSDC);
    (uint256 debtAdjustFactor, , , , ) = auditor.markets(marketWETH);
    assertApproxEqAbs(uint256(leverage.principal), principal, 2e18);
    assertApproxEqAbs(leverage.deposit, principal.mulWadDown(ratio), 1);
    assertApproxEqAbs(leverage.ratio, ratio, 0.0003e18);
    assertApproxEqAbs(
      leverage.maxRatio,
      uint256(1e18).divWadDown(1e18 - collateralAdjustFactor.mulWadDown(debtAdjustFactor)),
      0.000000004e18
    );
  }

  function testPreviewEmptyLeverage() external {
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    (uint256 collateralAdjustFactor, , , , ) = auditor.markets(marketUSDC);
    (uint256 debtAdjustFactor, , , , ) = auditor.markets(marketWETH);

    assertEq(leverage.principal, 0);
    assertEq(leverage.deposit, 0);
    assertEq(leverage.debt, 0);
    assertEq(leverage.ratio, 0);
    assertEq(leverage.maxRatio, uint256(1e18).divWadDown(1e18 - collateralAdjustFactor.mulWadDown(debtAdjustFactor)));
  }

  function testPreviewLeverageSameAsset() external {
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketUSDC, address(this), 1e18);
    (uint256 adjustFactor, , , , ) = auditor.markets(marketUSDC);
    uint256 principal = 1_000e6;
    uint256 ratio = leverage.maxRatio - 0.0001e18;

    debtManager.leverage(marketUSDC, principal, ratio);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
    assertEq(leverage.principal, 0);
    assertEq(leverage.deposit, 0);
    assertEq(leverage.debt, 0);
    assertEq(leverage.ratio, 0);
    assertEq(leverage.sqrtPriceX96, 0);
    assertEq(leverage.pool.token0, address(usdc));
    assertEq(leverage.pool.token1, address(usdc));
    assertEq(leverage.pool.fee, 0);
    assertEq(leverage.maxRatio, uint256(1e18).divWadDown(1e18 - adjustFactor.mulWadDown(adjustFactor)));

    leverage = debtPreviewer.leverage(marketUSDC, marketUSDC, address(this), 1e18);
    assertApproxEqAbs(uint256(leverage.principal), 1_000e6, 3);
    assertApproxEqAbs(leverage.deposit, principal.mulWadDown(ratio), 1);
    assertApproxEqAbs(leverage.debt, principal.mulWadDown(ratio - 1e18), 1);
    assertApproxEqAbs(leverage.ratio, ratio, 20267597440);
    assertApproxEqAbs(leverage.maxRatio, ratio, 99988365328679);
  }

  function testPreviewLeverageNegativePrincipal() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(0.1e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketwstETH, marketWETH, address(this), 1e18);
    assertEq(leverage.ratio, 0);
    assertEq(leverage.deposit, 0);
    assertEq(leverage.maxWithdraw, 0);
    assertApproxEqAbs(leverage.debt, 0.1 ether, 1);
    assertEq(leverage.maxRatio, 3048780487804878048);
    assertEq(leverage.principal, -88572673221028669);

    Limit memory limit = debtPreviewer.previewLeverage(marketwstETH, marketWETH, address(this), 1e18, 2e18, 1e18);
    debtManager.crossLeverage(marketwstETH, marketWETH, 500, 1e18, 2e18, MAX_SQRT_RATIO - 1);
    (, , uint256 floatingBorrowShares) = marketWETH.accounts(address(this));
    assertApproxEqAbs(limit.borrow, marketWETH.previewRefund(floatingBorrowShares), 1);
    assertApproxEqAbs(limit.deposit, marketwstETH.maxWithdraw(address(this)), 0);

    leverage = debtPreviewer.leverage(marketwstETH, marketWETH, address(this), 1e18);
    assertApproxEqAbs(leverage.principal, limit.principal, 3e15);
  }

  function testPreviewLeverageSameAssetNegativePrincipal() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(1e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketWETH, address(this), 1e18);
    assertEq(leverage.ratio, 0);
    assertEq(leverage.deposit, 0);
    assertEq(leverage.maxWithdraw, 0);
    assertApproxEqAbs(leverage.debt, 1 ether, 1);
    assertEq(leverage.maxRatio, 3396739130434782608);
    assertEq(leverage.principal, -1e18);

    Limit memory limit = debtPreviewer.previewLeverage(marketWETH, marketWETH, address(this), 1e18, 2e18, 1e18);
    (, , uint256 floatingBorrowShares) = marketWETH.accounts(address(this));
    assertEq(limit.principal, 0);
    assertEq(limit.borrow, marketWETH.previewRefund(floatingBorrowShares));
    assertEq(limit.maxRatio, 3396739130434782608);
    assertEq(limit.deposit, 1e18);

    limit = debtPreviewer.previewLeverage(marketWETH, marketWETH, address(this), 2e18, 3e18, 1e18);
    assertEq(limit.principal, 1e18);
    assertEq(limit.maxRatio, 3396739130434782608);
    assertEq(limit.deposit, 3e18);
    assertApproxEqAbs(limit.borrow, marketWETH.previewRefund(floatingBorrowShares) * 2, 2);

    debtManager.leverage(marketWETH, 2e18, 3e18);
    (, , floatingBorrowShares) = marketWETH.accounts(address(this));
    assertApproxEqAbs(limit.deposit, marketWETH.maxWithdraw(address(this)), 4);
    assertApproxEqAbs(limit.borrow, marketWETH.previewRefund(floatingBorrowShares), 1);
  }

  function testPreviewLeverageSameAssetPartialNegativePrincipal() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(1e18, address(this), address(this));
    marketWETH.deposit(0.5e18, address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketwstETH, marketWETH, address(this), 1.01e18);
    Limit memory limit = debtPreviewer.previewLeverage(
      marketWETH,
      marketWETH,
      address(this),
      leverage.minDeposit,
      4e18,
      1e18
    );
    debtManager.leverage(marketWETH, leverage.minDeposit, limit.ratio);
    (, , uint256 floatingBorrowShares) = marketWETH.accounts(address(this));
    assertApproxEqAbs(limit.deposit, marketWETH.maxWithdraw(address(this)), 4);
    assertApproxEqAbs(limit.borrow, marketWETH.previewRefund(floatingBorrowShares), 2);
  }

  function testPreviewLeveragePartialNegativePrincipal() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketwstETH.deposit(0.4e18, address(this));
    marketWETH.borrow(1e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketwstETH, marketWETH, address(this), 1e18);
    Limit memory limit = debtPreviewer.previewLeverage(
      marketwstETH,
      marketWETH,
      address(this),
      leverage.minDeposit,
      10e18,
      1e18
    );
    assertApproxEqAbs(limit.deposit, 0.4e18 + leverage.minDeposit, 1);
    debtManager.crossLeverage(marketwstETH, marketWETH, 500, leverage.minDeposit, limit.ratio, MAX_SQRT_RATIO - 1);
    assertApproxEqAbs(marketwstETH.maxWithdraw(address(this)), limit.deposit, 1);
  }

  function testPreviewLeverageNegativePrincipalWithCollateral() external {
    marketUSDC.deposit(20_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketwstETH.deposit(1e18, address(this));
    marketWETH.borrow(2e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketwstETH, marketWETH, address(this), 1e18);
    assertEq(leverage.ratio, 0);
    assertEq(leverage.deposit, 1e18);
    assertEq(leverage.minDeposit, 1636091464911567515);
    assertEq(leverage.maxWithdraw, 0);
    assertApproxEqAbs(leverage.debt, 2 ether, 1);
    assertEq(leverage.maxRatio, 3048780487804878048);
    assertEq(leverage.principal, -771453464420573369);

    uint256 ratio = 10e18;
    uint256 deposit = 1636091464911567515;
    Limit memory limit = debtPreviewer.previewLeverage(marketwstETH, marketWETH, address(this), deposit, ratio, 1e18);
    assertApproxEqAbs(limit.ratio, leverage.maxRatio, 3);
    assertApproxEqAbs(limit.deposit, 1e18 + deposit, 1);
    assertApproxEqAbs(limit.borrow, 2 ether, 4);
    debtManager.crossLeverage(marketwstETH, marketWETH, 500, deposit, limit.ratio, MAX_SQRT_RATIO - 1);
    leverage = debtPreviewer.leverage(marketwstETH, marketWETH, address(this), 1e18);
    (, , uint256 floatingBorrowShares) = marketWETH.accounts(address(this));
    assertApproxEqAbs(limit.borrow, marketWETH.previewRefund(floatingBorrowShares), 4);
    assertApproxEqAbs(limit.deposit, marketwstETH.maxWithdraw(address(this)), 1);
  }

  function testPreviewLeveragePoolInfo() external {
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    assertEq(leverage.pool.token0, address(weth));
    assertEq(leverage.pool.token1, address(usdc));
    assertEq(leverage.pool.fee, 500);
    assertApproxEqAbs((leverage.sqrtPriceX96 * leverage.sqrtPriceX96 * 1e18) >> (96 * 2), 1810e6, 1e6);
    leverage = debtPreviewer.leverage(marketWETH, marketUSDC, address(this), 1e18);
    assertEq(leverage.pool.token0, address(weth));
    assertEq(leverage.pool.token1, address(usdc));
    assertEq(leverage.pool.fee, 500);
    assertApproxEqAbs((leverage.sqrtPriceX96 * leverage.sqrtPriceX96 * 1e18) >> (96 * 2), 1810e6, 1e6);
    leverage = debtPreviewer.leverage(marketWETH, marketwstETH, address(this), 1e18);
    assertEq(leverage.pool.token0, address(wstETH));
    assertEq(leverage.pool.token1, address(weth));
    assertEq(leverage.pool.fee, 500);
    leverage = debtPreviewer.leverage(marketwstETH, marketWETH, address(this), 1e18);
    assertEq(leverage.pool.token0, address(wstETH));
    assertEq(leverage.pool.token1, address(weth));
    assertEq(leverage.pool.fee, 500);
  }

  function testPreviewLeverageBalancerAvailableLiquidity() external {
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    Market[] memory markets = auditor.allMarkets();
    assertEq(leverage.availableAssets.length, markets.length);
    assertEq(address(leverage.availableAssets[1].asset), address(usdc));
    assertEq(leverage.availableAssets[1].liquidity, usdc.balanceOf(address(debtManager.balancerVault())));
  }

  function testPreviewLeverageMaxRatioSingleCollateralAndDebt() external {
    uint256 ratio = 2e18;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 10_000e6, ratio, MIN_SQRT_RATIO + 1);

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    ratio = leverage.maxRatio - 0.01e18;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, ratio, MIN_SQRT_RATIO + 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewCrossLeverageWithUSDCDeposit() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketWETH.borrow(0.5e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    uint256 newDeposit = 3_000e6;
    Limit memory limit = debtPreviewer.previewLeverage(
      marketUSDC,
      marketWETH,
      address(this),
      newDeposit,
      leverage.ratio,
      1e18
    );
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, newDeposit, limit.maxRatio - 0.005e18, MIN_SQRT_RATIO + 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewCrossLeverageWithWETHDeposit() external {
    marketWETH.deposit(5e18, address(this));
    auditor.enterMarket(marketWETH);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketUSDC.borrow(2_000e6, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketUSDC, address(this), 1e18);
    uint256 newDeposit = 3e18;
    Limit memory limit = debtPreviewer.previewLeverage(
      marketWETH,
      marketUSDC,
      address(this),
      newDeposit,
      leverage.ratio,
      1e18
    );
    debtManager.crossLeverage(marketWETH, marketUSDC, 500, newDeposit, limit.maxRatio - 0.015e18, MAX_SQRT_RATIO - 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewCrossAssetInvalidLeverageShouldReturnAccurateRatio() external {
    marketWETH.deposit(5e18, address(this));
    marketWETH.borrow(1e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    Limit memory limit = debtPreviewer.previewLeverage(
      marketUSDC,
      marketWETH,
      address(this),
      leverage.minDeposit,
      2e18,
      1e18
    );
    assertApproxEqAbs(leverage.maxRatio, limit.ratio, 1e11);
    limit = debtPreviewer.previewLeverage(marketUSDC, marketWETH, address(this), leverage.minDeposit, 8e18, 1e18);
    assertApproxEqAbs(leverage.maxRatio, limit.ratio, 1e11);

    debtManager.crossLeverage(marketUSDC, marketWETH, 500, leverage.minDeposit, limit.ratio, MIN_SQRT_RATIO + 1);
  }

  function testPreviewSameAssetInvalidLeverageShouldCapRatio() external {
    marketWETH.deposit(5e18, address(this));
    auditor.enterMarket(marketWETH);
    marketUSDC.borrow(5_000e6, address(this), address(this));

    Limit memory limit = debtPreviewer.previewLeverage(marketUSDC, marketUSDC, address(this), 6_000e6, 5e18, 1e18);
    assertEq(limit.ratio, 6000000006000000007);
  }

  function testPreviewLeverageSameUSDCAssetWithDeposit() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketWETH.borrow(2.3e18, address(this), address(this));

    uint256 newDeposit = 5_000e6;
    Limit memory limit = debtPreviewer.previewLeverage(marketUSDC, marketUSDC, address(this), newDeposit, 1e18, 1e18);
    debtManager.leverage(marketUSDC, newDeposit, limit.maxRatio - 0.003e18);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageMaxWithdraw() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(1_000e18, address(this), address(this));

    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, 2.5e18, MIN_SQRT_RATIO + 1);
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    debtManager.crossDeleverage(marketUSDC, marketWETH, 500, leverage.maxWithdraw, 1e18, MAX_SQRT_RATIO - 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewMaxRatioWithdrawX() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(1_500e18, address(this), address(this));

    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, 2.5e18, MIN_SQRT_RATIO + 1);
    uint256 withdrawAssets = 3_000e6;
    Limit memory limit = debtPreviewer.previewDeleverage(
      marketUSDC,
      marketWETH,
      address(this),
      withdrawAssets,
      1e18,
      1e18
    );
    debtManager.crossDeleverage(
      marketUSDC,
      marketWETH,
      500,
      withdrawAssets,
      limit.maxRatio - 0.005e18,
      MAX_SQRT_RATIO - 1
    );
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);

    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0004e18);
  }

  function testPreviewMaxRatioWithdrawWithMinHealthFactor() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(1_500e18, address(this), address(this));
    uint256 minHF = 1.03e18;

    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, 2.5e18, MIN_SQRT_RATIO + 1);
    uint256 withdraw = 3_000e6;

    Limit memory limit = debtPreviewer.previewDeleverage(marketUSDC, marketWETH, address(this), withdraw, 1e18, minHF);

    debtManager.crossDeleverage(marketUSDC, marketWETH, 500, withdraw, limit.maxRatio - 0.005e18, MAX_SQRT_RATIO - 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), minHF, 0.0005e18);
  }

  function testPreviewMultipleMaxRatioWithdraw() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(1_000e18, address(this), address(this));
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, 2.5e18, MIN_SQRT_RATIO + 1);

    assertApproxEqAbs(
      debtPreviewer.previewDeleverage(marketUSDC, marketWETH, address(this), 1_000e6, 1e18, 1e18).maxRatio,
      3.1e18,
      0.02e18
    );
    assertApproxEqAbs(
      debtPreviewer.previewDeleverage(marketUSDC, marketWETH, address(this), 2_000e6, 1e18, 1e18).maxRatio,
      2.97e18,
      0.02e18
    );
    assertApproxEqAbs(
      debtPreviewer.previewDeleverage(marketUSDC, marketWETH, address(this), 3_000e6, 1e18, 1e18).maxRatio,
      2.78e18,
      0.02e18
    );
    assertApproxEqAbs(
      debtPreviewer.previewDeleverage(marketUSDC, marketWETH, address(this), 4_000e6, 1e18, 1e18).maxRatio,
      2.54e18,
      0.02e18
    );
    Limit memory limit = debtPreviewer.previewDeleverage(marketUSDC, marketWETH, address(this), 5_000e6, 1e18, 1e18);
    assertApproxEqAbs(limit.maxRatio, 2.22e18, 0.02e18);
    debtManager.crossDeleverage(marketUSDC, marketWETH, 500, 5_000e6, limit.maxRatio - 0.005e18, MAX_SQRT_RATIO - 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewMaxRatioWithdrawWithoutDebt() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, 2.5e18, MIN_SQRT_RATIO + 1);

    assertApproxEqAbs(
      debtPreviewer.previewDeleverage(marketUSDC, marketWETH, address(this), 1_000e6, 1e18, 1e18).maxRatio,
      4.24e18,
      0.005e18
    );
    assertApproxEqAbs(
      debtPreviewer.previewDeleverage(marketUSDC, marketWETH, address(this), 4_000e6, 1e18, 1e18).maxRatio,
      4.24e18,
      0.005e18
    );
  }

  function testPreviewMaxRatioWithdrawWithSameAssetLeverage() external {
    debtManager.leverage(marketUSDC, 100_000e6, 4e18);
    assertApproxEqAbs(
      debtPreviewer.previewDeleverage(marketUSDC, marketUSDC, address(this), 10_000e6, 1e18, 1e18).maxRatio,
      5.81e18,
      0.008e18
    );
    assertApproxEqAbs(
      debtPreviewer.previewDeleverage(marketUSDC, marketUSDC, address(this), 40_000e6, 1e18, 1e18).maxRatio,
      5.81e18,
      0.008e18
    );
  }

  function testPreviewLeverageMaxWithdrawWithSameMarketOutDebt() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(1e18, address(this), address(this));

    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, 2.5e18, MIN_SQRT_RATIO + 1);
    marketWETH.borrow(0.5e18, address(this), address(this));
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    debtManager.crossDeleverage(marketUSDC, marketWETH, 500, leverage.maxWithdraw, 1e18, MAX_SQRT_RATIO - 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(marketUSDC.balanceOf(address(this)), 1);
    assertApproxEqAbs(coll, 0, 1e13);
    assertEq(debt, 0);
  }

  function testPreviewLeverageMaxWithdrawWithFixedDebt() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketWETH.borrowAtMaturity(maturity, 1e18, 2e18, address(this), address(this));
    marketUSDC.borrowAtMaturity(maturity, 500e6, 800e6, address(this), address(this));

    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, 2.5e18, MIN_SQRT_RATIO + 1);
    marketWETH.borrow(0.5e18, address(this), address(this));
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    debtManager.crossDeleverage(marketUSDC, marketWETH, 500, leverage.maxWithdraw, 1e18, MAX_SQRT_RATIO - 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageMaxWithdrawWithDeleverageSameRatio() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketWETH.borrowAtMaturity(maturity, 1e18, 2e18, address(this), address(this));
    marketUSDC.borrowAtMaturity(maturity, 500e6, 800e6, address(this), address(this));
    marketOP.borrow(200e18, address(this), address(this));

    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, 2.5e18, MIN_SQRT_RATIO + 1);
    marketWETH.borrow(0.5e18, address(this), address(this));
    debtManager.crossDeleverage(marketUSDC, marketWETH, 500, 300e6, 1.5e18, MAX_SQRT_RATIO - 1);
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    assertApproxEqAbs(leverage.ratio, 1.5e18, 1e16);
  }

  function testPreviewLeverageUSDCMaxRatioMultipleCollateralAndDebt() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketWETH.borrow(0.5e18, address(this), address(this));
    marketUSDC.borrowAtMaturity(maturity, 200e6, 400e6, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    uint256 ratio = leverage.maxRatio - 0.005e18;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, ratio, MIN_SQRT_RATIO + 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageUSDCMaxRatioMultipleCollateralAndFixedDebt() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketWETH.borrow(0.5e18, address(this), address(this));
    marketWETH.borrowAtMaturity(maturity, 0.5e18, 1e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    uint256 ratio = leverage.maxRatio - 0.003e18;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, ratio, MIN_SQRT_RATIO + 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageWETHMaxRatioMultipleCollateralAndDebt() external {
    marketWETH.deposit(5e18, address(this));
    auditor.enterMarket(marketWETH);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketUSDC.borrow(1_000e6, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketUSDC, address(this), 1e18);
    uint256 ratio = leverage.maxRatio - 0.01e18;
    debtManager.crossLeverage(marketWETH, marketUSDC, 500, 0, ratio, MAX_SQRT_RATIO - 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageWETHMaxRatioMultipleCollateralAndDebtWithMinHealthFactor() external {
    marketWETH.deposit(5e18, address(this));
    auditor.enterMarket(marketWETH);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketUSDC.borrow(1_000e6, address(this), address(this));
    uint256 minHealthFactor = 1.04e18;

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketUSDC, address(this), minHealthFactor);
    uint256 ratio = leverage.maxRatio - 0.01e18;
    debtManager.crossLeverage(marketWETH, marketUSDC, 500, 0, ratio, MAX_SQRT_RATIO - 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), minHealthFactor, 0.0005e18);
  }

  function testPreviewLeverageSameUSDCAssetMaxRatioMultipleCollateralAndDebt() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketWETH.borrow(0.5e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketUSDC, address(this), 1e18);
    debtManager.leverage(marketUSDC, 0, leverage.maxRatio - 0.005e18);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageSameWETHAssetMaxRatioMultipleCollateralAndDebt() external {
    marketWETH.deposit(5e18, address(this));
    auditor.enterMarket(marketWETH);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketUSDC.borrow(2_000e6, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketWETH, address(this), 1e18);
    debtManager.leverage(marketWETH, 0, leverage.maxRatio - 0.0005e18);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageSameWETHAssetMultipleCollateralAndDebtWithMinHealthFactor() external {
    marketWETH.deposit(5e18, address(this));
    auditor.enterMarket(marketWETH);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketUSDC.borrow(2_000e6, address(this), address(this));
    uint256 minHealthFactor = 1.05e18;

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketWETH, address(this), minHealthFactor);
    debtManager.leverage(marketWETH, 0, leverage.maxRatio - 0.0005e18);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), minHealthFactor, 0.0003e18);
  }

  function testPreviewLeverageEmptyMarketIn() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(0.5e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketUSDC, address(this), 1e18);
    (uint256 collateralAdjustFactor, , , , ) = auditor.markets(marketWETH);
    (uint256 debtAdjustFactor, , , , ) = auditor.markets(marketUSDC);
    assertEq(leverage.principal, 0);
    assertEq(leverage.deposit, 0);
    assertEq(leverage.debt, 0);
    assertEq(leverage.ratio, 0);
    assertEq(leverage.maxRatio, uint256(1e18).divWadDown(1e18 - collateralAdjustFactor.mulWadDown(debtAdjustFactor)));
  }

  function testPreviewLeverageMaxRatioSameAssetUSDCBorrow() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketUSDC.borrow(2_000e6, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    uint256 ratio = leverage.maxRatio - 0.005e18;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, ratio, MIN_SQRT_RATIO + 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageMaxRatioSameAssetUSDCBorrowWithMinHealthFactor() external {
    uint256 minHealthFactor = 1.05e18;
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketUSDC.borrow(2_000e6, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), minHealthFactor);
    uint256 ratio = leverage.maxRatio - 0.005e18;
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, ratio, MIN_SQRT_RATIO + 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), minHealthFactor, 0.0004e18);
  }

  function testPreviewLeverageMaxRatioSameAssetWETHBorrow() external {
    marketWETH.deposit(5e18, address(this));
    auditor.enterMarket(marketWETH);
    marketWETH.borrow(1e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketUSDC, address(this), 1e18);
    uint256 ratio = leverage.maxRatio - 0.015e18;
    debtManager.crossLeverage(marketWETH, marketUSDC, 500, 0, ratio, MAX_SQRT_RATIO - 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewDeleverageCrossAsset() external {
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 100_000e6, 3e18, MIN_SQRT_RATIO + 1);

    Limit memory limit = debtPreviewer.previewDeleverage(marketUSDC, marketWETH, address(this), 10_000e6, 2e18, 1e18);

    debtManager.crossDeleverage(marketUSDC, marketWETH, 500, 10_000e6, 2e18, MAX_SQRT_RATIO - 1);
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), limit.deposit, 2);
    assertEq(floatingBorrowAssets(marketWETH, address(this)), limit.borrow);

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    assertApproxEqAbs(leverage.maxRatio, limit.maxRatio, 6e8);

    vm.expectRevert(abi.encodeWithSelector(InsufficientAccountLiquidity.selector));
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, limit.maxRatio, MIN_SQRT_RATIO + 1);

    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, limit.maxRatio - 7e16, MIN_SQRT_RATIO + 1);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.00031e18);
  }

  function testPreviewDeleverageSameAsset() external {
    debtManager.leverage(marketUSDC, 100_000e6, 3e18);

    Limit memory limit = debtPreviewer.previewDeleverage(marketUSDC, marketUSDC, address(this), 10_000e6, 2e18, 1e18);

    debtManager.deleverage(marketUSDC, 10_000e6, 2e18);
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), limit.deposit, 2);
    assertApproxEqAbs(floatingBorrowAssets(marketUSDC, address(this)), limit.borrow, 1);

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketUSDC, address(this), 1e18);
    assertApproxEqAbs(leverage.maxRatio, limit.maxRatio, 6e8);

    vm.expectRevert(abi.encodeWithSelector(InsufficientAccountLiquidity.selector));
    debtManager.leverage(marketUSDC, 0, limit.maxRatio + 0.001e18);

    debtManager.leverage(marketUSDC, 0, limit.maxRatio);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 5e7);
  }

  function testPreviewDeleverageWithdrawHigherThanMaxWithdraw() external {
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 100_000e6, 3e18, MIN_SQRT_RATIO + 1);

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);

    vm.expectRevert(InvalidPreview.selector);
    debtPreviewer.previewDeleverage(marketUSDC, marketWETH, address(this), leverage.maxWithdraw + 1, 1e18, 1e18);
  }

  function testPreviewDeleverageWithdrawHigherThanMaxWithdrawAndLessThanPrincipal() external {
    marketUSDC.deposit(100_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(1 ether, address(this), address(this));
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);

    vm.expectRevert(stdError.arithmeticError);
    debtPreviewer.previewDeleverage(
      marketUSDC,
      marketWETH,
      address(this),
      leverage.maxWithdraw + 1e6,
      leverage.ratio,
      1e18
    );
    Limit memory limit = debtPreviewer.previewDeleverage(
      marketUSDC,
      marketWETH,
      address(this),
      leverage.maxWithdraw,
      1e18,
      1e18
    );

    debtManager.crossDeleverage(marketUSDC, marketWETH, 500, leverage.maxWithdraw, 1e18, MAX_SQRT_RATIO - 1);

    assertEq(marketUSDC.maxWithdraw(address(this)), limit.deposit);
    assertEq(floatingBorrowAssets(marketWETH, address(this)), limit.borrow);
  }

  function testPreviewDeleverageWithNegativePrincipal() external {
    marketUSDC.deposit(100_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(10 ether, address(this), address(this));

    vm.expectRevert(InvalidPreview.selector);
    debtPreviewer.previewDeleverage(marketOP, marketWETH, address(this), 0, 1e18, 1e18);
    vm.expectRevert(InvalidPreview.selector);
    debtPreviewer.previewDeleverage(marketOP, marketWETH, address(this), 1 ether, 1e18, 1e18);
    vm.expectRevert(InvalidPreview.selector);
    debtPreviewer.previewDeleverage(marketOP, marketWETH, address(this), 1 ether, 2e18, 1e18);
    vm.expectRevert(InvalidPreview.selector);
    debtPreviewer.previewDeleverage(marketWETH, marketWETH, address(this), 1 ether, 1e18, 1e18);
  }

  function testPreviewDeleverageMaxWithdrawWithRatioHigherThanOne() external {
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 100_000e6, 3e18, MIN_SQRT_RATIO + 1);

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);

    Limit memory limit = debtPreviewer.previewDeleverage(
      marketUSDC,
      marketWETH,
      address(this),
      leverage.maxWithdraw,
      1.01e18,
      1e18
    );

    assertEq(limit.ratio, 1e18);
    assertEq(limit.maxRatio, 1e18);
    limit = debtPreviewer.previewDeleverage(marketUSDC, marketWETH, address(this), leverage.maxWithdraw, 1e18, 1e18);
    assertEq(limit.ratio, 1e18);
    assertEq(limit.maxRatio, 1e18);

    debtManager.crossDeleverage(marketUSDC, marketWETH, 500, leverage.maxWithdraw, 1e18, MAX_SQRT_RATIO - 1);

    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), limit.deposit, 0);
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), 0, 1);
    assertEq(floatingBorrowAssets(marketWETH, address(this)), limit.borrow);
    assertEq(floatingBorrowAssets(marketWETH, address(this)), 0);
  }

  function testPreviewDeleverageWithLowerRatioShouldCapRatio() external {
    marketUSDC.deposit(100_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(5_000 ether, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    debtManager.crossLeverage(marketUSDC, marketWETH, 500, 0, leverage.maxRatio - 0.1e18, MIN_SQRT_RATIO + 1);
    leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);

    Limit memory limit = debtPreviewer.previewDeleverage(
      marketUSDC,
      marketWETH,
      address(this),
      leverage.maxWithdraw / 2,
      leverage.ratio,
      1e18
    );
    assertEq(leverage.ratio, 3683445754740604291);
    assertEq(limit.ratio, 3345551396765711509);
    assertEq(limit.ratio, limit.maxRatio);

    vm.expectRevert(abi.encodeWithSelector(InsufficientAccountLiquidity.selector));
    debtManager.crossDeleverage(
      marketUSDC,
      marketWETH,
      500,
      leverage.maxWithdraw / 2,
      limit.ratio + 0.05e18,
      MAX_SQRT_RATIO - 1
    );

    debtManager.crossDeleverage(marketUSDC, marketWETH, 500, leverage.maxWithdraw / 2, limit.ratio, MAX_SQRT_RATIO - 1);
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), limit.deposit, 1);
    assertApproxEqAbs(floatingBorrowAssets(marketWETH, address(this)), limit.borrow, 1);
  }

  function testPreviewMinDeposit() external {
    marketWETH.deposit(5e18, address(this));
    marketWETH.borrow(1e18, address(this), address(this));

    (uint256 adjustFactorIn, , , , IPriceFeed priceFeedIn) = auditor.markets(marketUSDC);
    (uint256 adjustFactorOut, , , , IPriceFeed priceFeedOut) = auditor.markets(marketWETH);

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);

    assertApproxEqAbs(
      leverage
        .minDeposit
        .mulDivDown(auditor.assetPrice(priceFeedIn), 10 ** marketUSDC.decimals())
        .mulWadDown(adjustFactorIn)
        .divWadDown(
          floatingBorrowAssets(marketWETH, address(this)).mulWadDown(auditor.assetPrice(priceFeedOut)).divWadDown(
            adjustFactorOut
          )
        ),
      1e18,
      4e8
    );
  }

  function testMinDepositMaxRatio() external {
    marketWETH.deposit(5e18, address(this));
    marketWETH.borrow(1e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    marketUSDC.deposit(leverage.minDeposit, address(this));
    leverage = debtPreviewer.leverage(marketUSDC, marketWETH, address(this), 1e18);
    assertApproxEqAbs(leverage.ratio, leverage.maxRatio, 5e10);

    marketWETH.withdraw(5e18 - 2e8, address(this), address(this));

    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 7e7);
  }

  function testMinDepositZero() external {
    marketWETH.deposit(5e18, address(this));
    marketWETH.borrow(1e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketWETH, address(this), 1e18);

    assertEq(leverage.minDeposit, 0);
  }

  function crossPrincipal(Market marketDeposit, Market marketBorrow, address account) internal view returns (int256) {
    (, , , , IPriceFeed priceFeedIn) = debtManager.auditor().markets(marketDeposit);
    (, , , , IPriceFeed priceFeedOut) = debtManager.auditor().markets(marketBorrow);

    uint256 collateral = marketDeposit.maxWithdraw(account);
    uint256 debt = floatingBorrowAssets(marketBorrow, account)
      .mulDivDown(debtManager.auditor().assetPrice(priceFeedOut), 10 ** marketBorrow.decimals())
      .mulDivDown(10 ** marketDeposit.decimals(), debtManager.auditor().assetPrice(priceFeedIn));
    return int256(collateral) - int256(debt);
  }

  function floatingBorrowAssets(Market market, address account) internal view returns (uint256) {
    (, , uint256 floatingBorrowShares) = market.accounts(account);
    return market.previewRefund(floatingBorrowShares);
  }
}
