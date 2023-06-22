// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ForkTest } from "./Fork.t.sol";
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
  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
  DebtPreviewer internal debtPreviewer;
  DebtManager internal debtManager;
  ERC20 internal weth;
  ERC20 internal usdc;
  ERC20 internal wstETH;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 99_811_375);
    Auditor auditor = Auditor(deployment("Auditor"));
    IPermit2 permit2 = IPermit2(deployment("Permit2"));
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

    debtPreviewer = new DebtPreviewer(debtManager, IUniswapQuoter(deployment("UniswapV3Quoter")));
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
}
