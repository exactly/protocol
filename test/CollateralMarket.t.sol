// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Auditor, IPriceFeed, InsufficientAccountLiquidity } from "../contracts/Auditor.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import { InterestRateModel } from "../contracts/InterestRateModel.sol";
import { MockInterestRateModel } from "../contracts/mocks/MockInterestRateModel.sol";
import { CollateralMarket, Market } from "../contracts/CollateralMarket.sol";

contract CollateralMarketTest is Test {
  address internal constant BOB = address(0x69);
  address internal constant ALICE = address(0x420);

  Market internal marketWETH;
  Auditor internal auditor;
  MockERC20 internal weth;
  MockPriceFeed internal priceFeed;
  CollateralMarket internal market;

  function setUp() external {
    MockERC20 asset = new MockERC20("DAI", "DAI", 18);
    weth = new MockERC20("WETH", "WETH", 18);

    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    vm.label(address(auditor), "Auditor");

    market = CollateralMarket(address(new ERC1967Proxy(address(new CollateralMarket(asset, auditor)), "")));
    market.initialize(1e18);
    vm.label(address(market), "CollateralMarketDAI");
    priceFeed = new MockPriceFeed(18, 1e18);

    marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      12,
      1e18,
      InterestRateModel(address(new MockInterestRateModel(0.1e18))),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    vm.label(address(marketWETH), "MarketWETH");

    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.9e18);
    auditor.enterMarket(marketWETH);

    vm.label(BOB, "Bob");
    vm.label(ALICE, "Alice");
    asset.mint(BOB, 50_000 ether);
    asset.mint(ALICE, 50_000 ether);
    asset.mint(address(this), 1_000_000 ether);
    weth.mint(address(this), 1_000_000 ether);

    asset.approve(address(market), type(uint256).max);
    weth.approve(address(marketWETH), type(uint256).max);
    vm.prank(BOB);
    asset.approve(address(market), type(uint256).max);
    vm.prank(BOB);
    weth.approve(address(marketWETH), type(uint256).max);
    vm.prank(ALICE);
    asset.approve(address(market), type(uint256).max);

    marketWETH.deposit(50_000 ether, address(0x666));
  }

  function test() external {
    auditor.enterMarket(Market(address(market)));
    market.deposit(50_000e18, address(this));
    uint256 balanceBefore = weth.balanceOf(address(this));
    marketWETH.borrow(1 ether, address(this), address(this));
    uint256 balanceAfter = weth.balanceOf(address(this));
    (, , uint256 floatingBorrowShares) = marketWETH.accounts(address(this));

    assertEq(floatingBorrowShares, 1 ether);
    assertEq(balanceAfter, balanceBefore + 1 ether);
  }
}
