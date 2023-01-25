// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { BaseForkTest } from "./BaseFork.t.sol";
import { MarketDAI, ERC20, DAIJoin, DAIPot, InterestRateModel } from "../../contracts/MarketDAI.sol";

contract MarketDAITest is BaseForkTest {
  MarketDAI internal market;
  ERC20 internal dai;

  function setUp() external {
    vm.createSelectFork(vm.envString("MAINNET_NODE"), 16_420_420);

    market = MarketDAI(deployment("MarketDAI"));
    dai = market.asset();

    InterestRateModel irm = market.interestRateModel();
    irm = new InterestRateModel(
      irm.fixedCurveA(),
      irm.fixedCurveB(),
      irm.fixedMaxUtilization(),
      irm.floatingCurveA(),
      irm.floatingCurveB(),
      irm.floatingMaxUtilization()
    );
    market.borrow(0, address(0), address(0));
    upgrade(address(market), address(new MarketDAI(dai, market.auditor())));
    vm.startPrank(deployment("TimelockController"));
    market.setInterestRateModel(irm);
    market.dsrConfig(DAIPot(deployment("DAIPot")), DAIJoin(deployment("DAIJoin")));
    vm.stopPrank();

    deal(address(dai), address(this), 100_000_000e18);
    dai.approve(address(market), type(uint256).max);
  }

  function testDepositAndRedeem() external {
    uint256 shares = market.deposit(100_000_000e18, address(this));

    vm.warp(block.timestamp + 365 days);

    market.redeem(shares, address(this), address(this));
  }
}
