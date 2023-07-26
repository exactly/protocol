// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ForkTest } from "./Fork.t.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Swapper, IPool, ERC20, WETH } from "../../contracts/periphery/Swapper.sol";

contract SwapperTest is ForkTest {
  using FixedPointMathLib for uint256;

  ERC20 internal exa;
  WETH internal weth;
  IPool internal pool;
  Swapper internal swapper;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 107_385_046);

    exa = ERC20(deployment("EXA"));
    weth = WETH(payable(deployment("WETH")));
    pool = IPool(deployment("EXAPool"));
    swapper = new Swapper(exa, weth, pool);

    deal(address(weth), address(this), 500 ether);
  }

  function testSwapBasic() external _checkBalance {
    uint256 balanceETH = address(this).balance;
    uint256 amountEXA = pool.getAmountOut(1 ether, weth);
    swapper.swap{ value: 1 ether }(payable(address(this)), 0, 0);

    assertEq(address(this).balance, balanceETH - 1 ether, "eth spent");
    assertEq(exa.balanceOf(address(this)), amountEXA, "exa received");
  }

  function testSwapWithKeepAmount() external _checkBalance {
    uint256 balanceETH = address(this).balance;
    uint256 amountEXA = pool.getAmountOut(0.9 ether, weth);
    swapper.swap{ value: 1 ether }(payable(address(this)), 0, 0.1 ether);

    assertEq(address(this).balance, balanceETH - 0.9 ether, "eth spent");
    assertEq(exa.balanceOf(address(this)), amountEXA, "exa received");
  }

  function testSwapWithKeepEqualToValue() external _checkBalance {
    uint256 balanceETH = address(this).balance;
    swapper.swap{ value: 1 ether }(payable(address(this)), 0, 1 ether);

    assertEq(address(this).balance, balanceETH, "eth spent");
    assertEq(exa.balanceOf(address(this)), 0, "exa received");
  }

  function testSwapWithKeepHigherThanValue() external _checkBalance {
    uint256 balanceETH = address(this).balance;
    swapper.swap{ value: 1 ether }(payable(address(this)), 0, 2 ether);

    assertEq(address(this).balance, balanceETH, "eth spent");
    assertEq(exa.balanceOf(address(this)), 0, "exa received");
  }

  function testSwapWithInaccurateSlippageSendsETHToAccount() external _checkBalance {
    uint256 balanceETH = address(this).balance;
    uint256 amountEXA = pool.getAmountOut(1 ether, weth);

    swapper.swap{ value: 1 ether }(payable(address(this)), amountEXA * 5, 0);
    assertEq(address(this).balance, balanceETH, "eth spent");
    assertEq(exa.balanceOf(address(this)), 0, "exa received");

    swapper.swap{ value: 1 ether }(payable(address(this)), amountEXA - 10e18, 0);
    assertEq(address(this).balance, balanceETH - 1 ether, "eth spent");
    assertEq(exa.balanceOf(address(this)), amountEXA, "exa received");
  }

  modifier _checkBalance() {
    _;
    assertEq(address(swapper).balance, 0);
  }

  // solhint-disable-next-line no-empty-blocks
  receive() external payable {}
}
