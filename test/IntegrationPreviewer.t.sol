// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

import { Auditor, Market, InsufficientAccountLiquidity } from "../contracts/Auditor.sol";
import { IntegrationPreviewer } from "../contracts/periphery/IntegrationPreviewer.sol";
import { ForkTest } from "./Fork.t.sol";

contract IntegrationPreviewerTest is ForkTest {
  using FixedPointMathLib for uint256;

  address internal constant USER = 0x291019ecdA53f4E841f6722fEf239C9Dd120e6d5;

  Auditor internal auditor;
  Market internal exaUSDC;
  IntegrationPreviewer internal previewer;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 122_565_907);

    auditor = Auditor(deployment("Auditor"));
    exaUSDC = Market(deployment("MarketUSDC"));
    exaUSDC = Market(deployment("MarketUSDC"));
    previewer = IntegrationPreviewer(address(new ERC1967Proxy(address(new IntegrationPreviewer(auditor)), "")));
    deployment("RewardsController");
    deployment("PriceFeedOP");
    deployment("PriceFeedUSDC");
    deployment("PriceFeedUSDC.e");
    deployment("PriceFeedWBTC");
    deployment("PriceFeedWETH");
    deployment("MarketOP");
    deployment("MarketUSDC.e");
    deployment("MarketWBTC");
    deployment("MarketWETH");
    vm.label(address(previewer), "IntegrationPreviewer");
    vm.label(address(exaUSDC.interestRateModel()), "InterestRateModelUSDC");
    vm.label(address(Market(deployment("MarketOP")).interestRateModel()), "InterestRateModelOP");
    vm.label(address(Market(deployment("MarketUSDC.e")).interestRateModel()), "InterestRateModelUSDC.e");
    vm.label(address(Market(deployment("MarketWBTC")).interestRateModel()), "InterestRateModelWBTC");
    vm.label(address(Market(deployment("MarketWETH")).interestRateModel()), "InterestRateModelWETH");
  }

  // solhint-disable func-name-mixedcase

  function test_healthFactor() external view {
    assertEq(previewer.healthFactor(USER), 1.135305841449548453e18);
    assertEq(previewer.healthFactor(address(0)), type(uint256).max);
  }

  function test_borrowLimit() external {
    vm.startPrank(USER);
    exaUSDC.borrow(previewer.borrowLimit(USER, exaUSDC, 1e18) - 1, USER, USER);
    assertEq(previewer.borrowLimit(USER, exaUSDC, 1e18), 0);

    vm.expectRevert(InsufficientAccountLiquidity.selector);
    exaUSDC.borrow(1, USER, USER);
  }

  // solhint-enable func-name-mixedcase
}
