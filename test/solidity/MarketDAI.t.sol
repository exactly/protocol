// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { BaseForkTest } from "./BaseFork.t.sol";
import { Auditor, IPriceFeed } from "../../contracts/Auditor.sol";
import { ERC20, DAIPot, DAIJoin, Market, MarketDAI, InterestRateModel } from "../../contracts/MarketDAI.sol";

contract MarketDAITest is BaseForkTest {
  MarketDAI internal market;
  Auditor internal auditor;
  DAIPot internal pot;
  ERC20 internal dai;

  address internal constant BOB = address(0x69);

  function setUp() external {
    vm.createSelectFork(vm.envString("MAINNET_NODE"), 16_420_420);

    dai = ERC20(deployment("DAI"));
    pot = DAIPot(deployment("DAIPot"));
    market = MarketDAI(deployment("MarketDAI"));
    auditor = market.auditor();

    market.borrow(0, address(0), address(0));
    InterestRateModel irm = market.interestRateModel();
    irm = new InterestRateModel(
      irm.fixedCurveA(),
      irm.fixedCurveB(),
      irm.fixedMaxUtilization(),
      irm.floatingCurveA(),
      irm.floatingCurveB(),
      irm.floatingMaxUtilization()
    );
    upgrade(address(market), address(new MarketDAI(dai, market.auditor())));
    vm.startPrank(deployment("TimelockController"));
    market.setInterestRateModel(irm);
    market.dsrConfig(pot, DAIJoin(deployment("DAIJoin")));
    vm.stopPrank();

    vm.label(BOB, "bob");
    deal(address(dai), BOB, 100_000_000e18);
    deal(address(dai), address(this), 100_000_000e18);
    vm.prank(BOB);
    dai.approve(address(market), type(uint256).max);
    dai.approve(address(market), type(uint256).max);
    vm.prank(BOB);
    auditor.enterMarket(market);
    auditor.enterMarket(market);
  }

  function testDepositAndRedeem() external {
    uint256 pie = pot.pie(address(market));
    uint256 shares = market.deposit(1_000_000e18, address(this));
    // vm.warp(block.timestamp + 365 days);
    market.redeem(shares, address(this), address(this));
    assertEq(pot.pie(address(market)), pie);
  }

  function testNewDeployment() external {
    auditor = Auditor(
      address(
        new ERC1967Proxy(
          address(new Auditor(18)),
          abi.encodeCall(Auditor.initialize, (Auditor.LiquidationIncentive(0.09e18, 0.01e18)))
        )
      )
    );
    market = MarketDAI(
      address(
        new ERC1967Proxy(
          address(new MarketDAI(dai, auditor)),
          abi.encodeCall(
            Market.initialize,
            (3, 1e18, market.interestRateModel(), 0.02e18 / uint256(1 days), 0, 0, 0.0046e18, 0.42e18)
          )
        )
      )
    );
    auditor.enableMarket(market, IPriceFeed(deployment("PriceFeedDAI")), 0.8e18);
    market.dsrConfig(pot, DAIJoin(deployment("DAIJoin")));

    // vm.startPrank(BOB);
    // dai.approve(address(market), type(uint256).max);
    // auditor.enterMarket(market);
    // uint256 bobShares = market.deposit(10_000_000e18, address(BOB));
    // uint256 borrowShares = market.borrow(1_000_000e18, BOB, BOB);
    // vm.stopPrank();

    dai.approve(address(market), type(uint256).max);
    uint256 shares = market.deposit(1_000_000e18, address(this));

    // vm.warp(block.timestamp + 365 days);

    // vm.startPrank(BOB);
    // market.refund(borrowShares, BOB);
    // market.redeem(bobShares, BOB, BOB);
    // vm.stopPrank();

    market.redeem(shares, address(this), address(this));

    // assertEq(market.totalSupply(), 0);
    // assertEq(pot.pie(address(market)), 0);
  }
}
