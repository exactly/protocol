// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import { BaseScript } from "./Base.s.sol";
import { Market, Auditor, ERC20 } from "../contracts/Market.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

contract CoinstoreScript is BaseScript {
  address public constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
  address public constant TREASURY = 0x23fD464e0b0eE21cEdEb929B19CABF9bD5215019;
  address public constant COINSTORE = 0xA03B00D21e6F1eFa80323aB7B23DF477FA51B89f;
  ERC20 public constant usdt = ERC20(0x94b008aA00579c1307B0EF2c499aD98a8ce58e58);
  Market public marketUSDCe;

  function run() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 119_751_100);
    ERC20 exa = ERC20(deployment("EXA"));
    ERC20 usdce = ERC20(deployment("USDC.e"));
    marketUSDCe = Market(deployment("MarketUSDC.e"));
    uint256 maxAmountIn = 30_010e6;
    uint256 amountOut = 30_000e6;
    uint256 exaAmount = 38_100e18;

    vm.prank(deployment("TimelockController"));
    exa.transfer(TREASURY, exaAmount);

    uint256 coinstoreUSDTBefore = usdt.balanceOf(COINSTORE);
    uint256 coinstoreEXABefore = exa.balanceOf(COINSTORE);
    uint24 poolFee = 100;

    vm.startBroadcast(TREASURY);

    marketUSDCe.withdraw(maxAmountIn, TREASURY, TREASURY);
    usdce.approve(SWAP_ROUTER, maxAmountIn);
    uint256 amountIn = ISwapRouter(SWAP_ROUTER).exactOutputSingle(
      ExactOutputSingleParams({
        tokenIn: address(usdce),
        tokenOut: address(usdt),
        fee: poolFee,
        recipient: COINSTORE,
        deadline: block.timestamp,
        amountOut: amountOut,
        amountInMaximum: maxAmountIn,
        sqrtPriceLimitX96: 0
      })
    );

    exa.transfer(COINSTORE, exaAmount);

    vm.stopBroadcast();

    assert(usdt.balanceOf(COINSTORE) - coinstoreUSDTBefore == amountOut);
    assert(exa.balanceOf(COINSTORE) - coinstoreEXABefore == exaAmount);

    emit log_named_decimal_uint("USDC.e spent           ", amountIn, 6);
    emit log_named_decimal_uint("USDT sent to coinstore ", usdt.balanceOf(COINSTORE) - coinstoreUSDTBefore, 6);
    emit log_named_decimal_uint("EXA sent to coinstore  ", exa.balanceOf(COINSTORE) - coinstoreEXABefore, 18);
  }
}

struct ExactOutputSingleParams {
  address tokenIn;
  address tokenOut;
  uint24 fee;
  address recipient;
  uint256 deadline;
  uint256 amountOut;
  uint256 amountInMaximum;
  uint160 sqrtPriceLimitX96;
}

interface ISwapRouter {
  function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}
