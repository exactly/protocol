// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { Strings } from "@openzeppelin/contracts-v4/utils/Strings.sol";
import { TimelockController } from "@openzeppelin/contracts-v4/governance/TimelockController.sol";
import { BaseScript } from "./Base.s.sol";
import { RewardsController, ERC20 } from "../contracts/RewardsController.sol";
import { FixedMarket, Market, InterestRateModel } from "../contracts/Market.sol";
import { InterestRateModel, Parameters } from "../contracts/InterestRateModel.sol";
import { Previewer, FixedLib } from "../contracts/periphery/Previewer.sol";
import "forge-std/console.sol";

contract RewardsScript is BaseScript {
  function run() external {
    string memory rpc = "https://opt-mainnet.nodereal.io/v1/2e0817401653436587db249feb0ee542";
    vm.createSelectFork(rpc, 134401438);
    Market marketUSDC = Market(deployment("MarketUSDC"));
    address timelock = deployment("TimelockController");

    InterestRateModel irm = new InterestRateModel(
      Parameters({
        minRate: 50000000000000000,
        naturalRate: 110000000000000000,
        maxUtilization: 1300000000000000000,
        naturalUtilization: 880000000000000000,
        growthSpeed: 1.3e18,
        sigmoidSpeed: 2.5e18,
        spreadFactor: 0.3e18,
        maturitySpeed: 0.5e18,
        timePreference: 0.2e18,
        fixedAllocation: 0.6e18,
        maxRate: 18.25e18
      }),
      marketUSDC
    );

    deal(address(marketUSDC.asset()), address(this), 100_000e6);
    marketUSDC.asset().approve(address(marketUSDC), 100_000e6);
    marketUSDC.deposit(10_000e6, address(this));
    marketUSDC.borrow(1_000e6, address(this), address(this));
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.borrowAtMaturity(maturity, 100e6, 200e6, address(this), address(this));

    upgrade(address(marketUSDC), address(new Market(marketUSDC.asset(), marketUSDC.auditor())));
    vm.startPrank(timelock);
    marketUSDC.setFixedMarket(new FixedMarket(marketUSDC));
    marketUSDC.setDampSpeed(0.000053e18, 0.4e18, 0.4e18, 0.000053e18);
    marketUSDC.setFixedBorrowFactors(0.4e18, 0.5e18, 0.25e18);
    marketUSDC.setInterestRateModel(irm);
    vm.stopPrank();

    vm.warp(block.timestamp + 3 minutes);

    marketUSDC.deposit(10_000e6, address(this));
    marketUSDC.borrow(1_000e6, address(this), address(this));
    marketUSDC.borrowAtMaturity(maturity, 100e6, 200e6, address(this), address(this));
  }
}
