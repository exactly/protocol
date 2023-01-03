// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { Auditor, IPriceFeed } from "../../contracts/Auditor.sol";
import { Market } from "../../contracts/Market.sol";
import { MockPriceFeed } from "../../contracts/mocks/MockPriceFeed.sol";
import {
  ERC20,
  RewardsController,
  InvalidInput,
  InvalidDistributionData,
  IndexOverflow
} from "../../contracts/RewardsController.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";

contract RewardsControllerTest is Test {
  address internal constant ALICE = address(0x420);

  RewardsController internal rewardsController;
  Auditor internal auditor;
  Market internal marketDAI;
  Market internal marketWETH;
  MockERC20 internal rewardsAsset;
  MockInterestRateModel internal irm;

  function setUp() external {
    vm.warp(0);
    MockERC20 dai = new MockERC20("DAI", "DAI", 18);
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    rewardsAsset = new MockERC20("OP", "OP", 18);

    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    irm = new MockInterestRateModel(0.1e18);

    marketDAI = Market(address(new ERC1967Proxy(address(new Market(dai, auditor)), "")));
    marketDAI.initialize(
      3,
      1e18,
      InterestRateModel(address(irm)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    MockPriceFeed daiPriceFeed = new MockPriceFeed(18, 1e18);
    auditor.enableMarket(marketDAI, daiPriceFeed, 0.8e18, 18);

    marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      3,
      1e18,
      InterestRateModel(address(irm)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.9e18, 18);

    rewardsController = new RewardsController();
    RewardsController.RewardsConfigInput[] memory configs = new RewardsController.RewardsConfigInput[](5);
    configs[0] = RewardsController.RewardsConfigInput({
      emissionPerSecond: 1,
      totalSupply: 0,
      distributionEnd: 10 days,
      market: marketDAI,
      operation: RewardsController.Operation.Deposit,
      maturity: 0,
      reward: address(rewardsAsset)
    });
    configs[1] = RewardsController.RewardsConfigInput({
      emissionPerSecond: 2,
      totalSupply: 0,
      distributionEnd: 10 days,
      market: marketWETH,
      operation: RewardsController.Operation.Borrow,
      maturity: 0,
      reward: address(rewardsAsset)
    });
    configs[2] = RewardsController.RewardsConfigInput({
      emissionPerSecond: 1,
      totalSupply: 0,
      distributionEnd: 10 days,
      market: marketDAI,
      operation: RewardsController.Operation.Borrow,
      maturity: 0,
      reward: address(rewardsAsset)
    });
    configs[3] = RewardsController.RewardsConfigInput({
      emissionPerSecond: 1,
      totalSupply: 0,
      distributionEnd: 10 days,
      market: marketDAI,
      operation: RewardsController.Operation.Deposit,
      maturity: FixedLib.INTERVAL,
      reward: address(rewardsAsset)
    });
    configs[4] = RewardsController.RewardsConfigInput({
      emissionPerSecond: 1,
      totalSupply: 0,
      distributionEnd: 10 days,
      market: marketDAI,
      operation: RewardsController.Operation.Borrow,
      maturity: FixedLib.INTERVAL,
      reward: address(rewardsAsset)
    });
    rewardsController.setDistributionOperations(configs);
    marketDAI.setRewardsController(rewardsController);
    marketWETH.setRewardsController(rewardsController);
    rewardsAsset.mint(address(rewardsController), 100 ether);

    dai.mint(address(this), 100 ether);
    dai.mint(ALICE, 100 ether);
    dai.approve(address(marketDAI), type(uint256).max);
    vm.prank(ALICE);
    dai.approve(address(marketDAI), type(uint256).max);
    weth.mint(address(this), 1_000 ether);
    weth.approve(address(marketWETH), type(uint256).max);
  }

  function testGetAccountRewardsDAIWithDeposit() external {
    marketDAI.deposit(100 ether, address(this));
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    vm.warp(3 days + 20 minutes);
    assertEq(
      rewardsController.getAccountRewards(address(this), address(rewardsAsset)),
      emissionPerSecond * (3 days + 20 minutes)
    );
    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 7 days);
  }

  function testGetAccountRewardsDAIWithMint() external {
    marketDAI.mint(100 ether, address(this));
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 7 days);
  }

  function testGetAccountRewardsDAIWithTransfer() external {
    marketDAI.deposit(100 ether, address(this));
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    marketDAI.transfer(ALICE, marketDAI.balanceOf(address(this)));

    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    assertEq(rewardsController.getAccountRewards(ALICE, address(rewardsAsset)), emissionPerSecond * 4 days);
  }

  function testGetAccountRewardsDAIWithTransferFrom() external {
    marketDAI.deposit(100 ether, address(this));
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    marketDAI.approve(address(this), type(uint256).max);
    marketDAI.transferFrom(address(this), ALICE, marketDAI.balanceOf(address(this)));

    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    assertEq(rewardsController.getAccountRewards(ALICE, address(rewardsAsset)), emissionPerSecond * 4 days);
  }

  function testGetAccountRewardsDAIWithWithdraw() external {
    marketDAI.deposit(100 ether, address(this));
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    marketDAI.withdraw(100 ether, address(this), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
  }

  function testGetAccountRewardsDAIWithRedeem() external {
    marketDAI.deposit(100 ether, address(this));
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    marketDAI.redeem(100 ether, address(this), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
  }

  function testGetAccountRewardsDAIWithFloatingBorrow() external {
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, ALICE);

    marketWETH.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWETH);
    marketDAI.borrow(50 ether, address(this), address(this));

    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Borrow,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 7 days);
  }

  function testGetAccountRewardsDAIWithFloatingRefund() external {
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, ALICE);

    marketWETH.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWETH);
    marketDAI.borrow(50 ether, address(this), address(this));

    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Borrow,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    marketDAI.refund(50 ether, address(this));

    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
  }

  function testGetAccountRewardsDAIWithFloatingRepay() external {
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, ALICE);

    marketWETH.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWETH);
    marketDAI.borrow(50 ether, address(this), address(this));

    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Borrow,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    marketDAI.repay(marketDAI.previewRefund(50 ether), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
  }

  function testGetAccountRewardsDAIWithFixedDeposit() external {
    marketDAI.depositAtMaturity(FixedLib.INTERVAL, 100 ether, 100 ether, address(this));

    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      FixedLib.INTERVAL,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);

    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 7 days);
  }

  function testGetAccountRewardsDAIWithFixedBorrow() external {
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, ALICE);

    marketWETH.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWETH);
    vm.warp(1 days);
    marketDAI.borrowAtMaturity(FixedLib.INTERVAL, 100 ether, 150 ether, address(this), address(this));

    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Borrow,
      FixedLib.INTERVAL,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 2 days);

    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 6 days);
  }

  function testGetAccountRewardsDAIWithWithdrawAtMaturity() external {
    marketDAI.depositAtMaturity(FixedLib.INTERVAL, 100 ether, 100 ether, address(this));

    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      FixedLib.INTERVAL,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    marketDAI.withdrawAtMaturity(FixedLib.INTERVAL, 100 ether, 0, address(this), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
  }

  function testGetAccountRewardsDAIWithRepayAtMaturity() external {
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, ALICE);

    marketWETH.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWETH);
    vm.warp(1 days);
    marketDAI.borrowAtMaturity(FixedLib.INTERVAL, 100 ether, 150 ether, address(this), address(this));

    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Borrow,
      FixedLib.INTERVAL,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 2 days);
    (uint256 principal, uint256 fee) = marketDAI.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    marketDAI.repayAtMaturity(FixedLib.INTERVAL, principal + fee, principal + fee, address(this));

    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 2 days);
  }

  function testGetAccountRewardsDAIWithTwoBorrows() external {
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, ALICE);

    marketWETH.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWETH);
    vm.warp(1 days);
    marketDAI.borrowAtMaturity(FixedLib.INTERVAL, 100 ether, 150 ether, address(this), address(this));

    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Borrow,
      FixedLib.INTERVAL,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 2 days);
    (uint256 principal, uint256 fee) = marketDAI.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    marketDAI.repayAtMaturity(FixedLib.INTERVAL, principal + fee, principal + fee, address(this));

    vm.warp(4 days);
    marketDAI.borrowAtMaturity(FixedLib.INTERVAL, 100 ether, 150 ether, address(this), address(this));

    vm.warp(6 days);
    assertEq(
      rewardsController.getAccountRewards(address(this), address(rewardsAsset)),
      emissionPerSecond * 2 days + emissionPerSecond * 2 days
    );
  }

  function testGetAccountRewardsDAIWithAnotherAccountInPool() external {
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );

    marketDAI.deposit(100 ether, address(this));
    vm.warp(5 days);
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, ALICE);

    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 5 days);
    assertEq(rewardsController.getAccountRewards(ALICE, address(rewardsAsset)), 0);

    vm.warp(7.5 days);
    assertEq(
      rewardsController.getAccountRewards(address(this), address(rewardsAsset)),
      emissionPerSecond * 5 days + (emissionPerSecond * 2.5 days) / 2
    );
    assertEq(rewardsController.getAccountRewards(ALICE, address(rewardsAsset)), (emissionPerSecond * 2.5 days) / 2);
  }

  function testGetAccountRewardsWETH() external {
    marketWETH.deposit(1 ether, address(this));
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketWETH,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 3 days);
    vm.warp(3 days + 20 minutes);
    assertEq(
      rewardsController.getAccountRewards(address(this), address(rewardsAsset)),
      emissionPerSecond * (3 days + 20 minutes)
    );
    vm.warp(7 days);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), emissionPerSecond * 7 days);
  }

  function testClaimRewards() external {
    marketDAI.deposit(100 ether, address(this));
    marketWETH.deposit(10 ether, address(this));

    vm.warp(4 days + 20 minutes);
    uint256 rewardsToBeClaimed = rewardsController.getAccountRewards(address(this), address(rewardsAsset));
    rewardsController.claimRewards(address(this));

    assertEq(rewardsAsset.balanceOf(address(this)), rewardsToBeClaimed);
    assertEq(rewardsController.getAccountRewards(address(this), address(rewardsAsset)), 0);
  }

  function testDistributionEnd() external {
    marketDAI.deposit(100 ether, address(this));
    marketWETH.deposit(10 ether, address(this));

    (, uint256 daiEmissionPerSecond, , uint256 daiDistributionEnd) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );
    (, uint256 wethEmissionPerSecond, , uint256 wethDistributionEnd) = rewardsController.getRewardsData(
      marketWETH,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(daiDistributionEnd);
    assertEq(
      rewardsController.getAccountRewards(address(this), address(rewardsAsset)),
      daiEmissionPerSecond * daiDistributionEnd + wethEmissionPerSecond * wethDistributionEnd
    );

    vm.warp(daiDistributionEnd + 4 days + 20 minutes);
    assertEq(
      rewardsController.getAccountRewards(address(this), address(rewardsAsset)),
      daiEmissionPerSecond * daiDistributionEnd + wethEmissionPerSecond * wethDistributionEnd
    );
  }

  function testEmissionPerSecond() external {
    vm.warp(1 days);
    marketDAI.deposit(100 ether, address(this));

    address[] memory rewards = new address[](1);
    rewards[0] = address(rewardsAsset);
    uint88[] memory emissionsPerSecond = new uint88[](1);

    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );
    emissionsPerSecond[0] = uint88(emissionPerSecond * 2);
    rewardsController.setEmissionPerSecond(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      rewards,
      emissionsPerSecond
    );
    (, uint256 newEmissionPerSecond, , ) = rewardsController.getRewardsData(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      address(rewardsAsset)
    );
    assertEq(newEmissionPerSecond, emissionPerSecond * 2);
  }

  function testEmissionPerSecondWithLengthMismatchShouldRevert() external {
    address[] memory rewards = new address[](1);
    rewards[0] = address(rewardsAsset);
    uint88[] memory emissionsPerSecond = new uint88[](2);
    emissionsPerSecond[0] = uint88(1);
    emissionsPerSecond[1] = uint88(2);

    vm.expectRevert(InvalidInput.selector);
    rewardsController.setEmissionPerSecond(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      rewards,
      emissionsPerSecond
    );
  }

  function testEmissionPerSecondWithZeroLastUpdateShouldRevert() external {
    address[] memory rewards = new address[](1);
    rewards[0] = address(rewardsAsset);
    uint88[] memory emissionsPerSecond = new uint88[](1);
    emissionsPerSecond[0] = uint88(1);

    vm.expectRevert(InvalidDistributionData.selector);
    rewardsController.setEmissionPerSecond(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      rewards,
      emissionsPerSecond
    );
  }

  function testEmissionPerSecondWithZeroDecimalsShouldRevert() external {
    MockERC20 asset = new MockERC20("TEST", "TEST", 0);
    Market market = Market(address(new ERC1967Proxy(address(new Market(asset, auditor)), "")));
    market.initialize(3, 1e18, InterestRateModel(address(irm)), 0.02e18 / uint256(1 days), 1e17, 0, 0.0046e18, 0.42e18);
    RewardsController.RewardsConfigInput[] memory configs = new RewardsController.RewardsConfigInput[](1);
    configs[0] = RewardsController.RewardsConfigInput({
      emissionPerSecond: 1,
      totalSupply: 0,
      distributionEnd: 10 days,
      market: market,
      operation: RewardsController.Operation.Deposit,
      maturity: FixedLib.INTERVAL,
      reward: address(rewardsAsset)
    });
    rewardsController.setDistributionOperations(configs);
    asset.mint(address(this), 100 ether);
    asset.approve(address(market), type(uint256).max);
    market.depositAtMaturity(FixedLib.INTERVAL, 100 ether, 100 ether, address(this));

    vm.warp(1 days);

    address[] memory rewards = new address[](1);
    rewards[0] = address(rewardsAsset);
    uint88[] memory emissionsPerSecond = new uint88[](1);
    emissionsPerSecond[0] = uint88(1);

    vm.expectRevert(InvalidDistributionData.selector);
    rewardsController.setEmissionPerSecond(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      rewards,
      emissionsPerSecond
    );
  }

  function testIndexOverflowShouldRevert() external {
    vm.warp(1 days);
    marketDAI.deposit(1, address(this));

    address[] memory rewards = new address[](1);
    rewards[0] = address(rewardsAsset);
    uint88[] memory emissionsPerSecond = new uint88[](1);
    emissionsPerSecond[0] = type(uint88).max;
    rewardsController.setEmissionPerSecond(
      marketDAI,
      RewardsController.Operation.Deposit,
      0,
      rewards,
      emissionsPerSecond
    );
    vm.warp(2 days);
    vm.expectRevert(IndexOverflow.selector);
    marketDAI.deposit(1, address(this));
  }
}
