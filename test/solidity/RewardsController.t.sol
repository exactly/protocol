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
import { ERC20, RewardsController } from "../../contracts/RewardsController.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";

contract RewardsControllerTest is Test {
  address internal constant ALICE = address(0x420);

  RewardsController internal rewardsController;
  Auditor internal auditor;
  Market internal marketDAI;
  Market internal marketWETH;
  MockERC20 internal rewardsAsset;

  function setUp() external {
    vm.warp(0);
    MockERC20 dai = new MockERC20("DAI", "DAI", 18);
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    rewardsAsset = new MockERC20("OP", "OP", 18);

    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    MockInterestRateModel irm = new MockInterestRateModel(0.1e18);

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
      asset: address(marketDAI),
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0,
      reward: address(rewardsAsset)
    });
    configs[1] = RewardsController.RewardsConfigInput({
      emissionPerSecond: 2,
      totalSupply: 0,
      distributionEnd: 10 days,
      asset: address(marketWETH),
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0,
      reward: address(rewardsAsset)
    });
    configs[2] = RewardsController.RewardsConfigInput({
      emissionPerSecond: 1,
      totalSupply: 0,
      distributionEnd: 10 days,
      asset: address(marketDAI),
      operation: RewardsController.Operation.FloatingBorrow,
      maturity: 0,
      reward: address(rewardsAsset)
    });
    configs[3] = RewardsController.RewardsConfigInput({
      emissionPerSecond: 1,
      totalSupply: 0,
      distributionEnd: 10 days,
      asset: address(marketDAI),
      operation: RewardsController.Operation.FixedDeposit,
      maturity: FixedLib.INTERVAL,
      reward: address(rewardsAsset)
    });
    configs[4] = RewardsController.RewardsConfigInput({
      emissionPerSecond: 1,
      totalSupply: 0,
      distributionEnd: 10 days,
      asset: address(marketDAI),
      operation: RewardsController.Operation.FixedBorrow,
      maturity: FixedLib.INTERVAL,
      reward: address(rewardsAsset)
    });
    rewardsController.configureAssets(configs);
    marketDAI.setRewardsController(rewardsController);
    rewardsAsset.mint(address(rewardsController), 100 ether);

    dai.mint(address(this), 100 ether);
    dai.mint(ALICE, 100 ether);
    dai.approve(address(marketDAI), type(uint256).max);
    vm.prank(ALICE);
    dai.approve(address(marketDAI), type(uint256).max);
    weth.mint(address(this), 100 ether);
    weth.approve(address(marketWETH), type(uint256).max);
  }

  function testGetUserRewardsDAIWithDeposit() external {
    marketDAI.deposit(100 ether, address(this));
    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FloatingDeposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    vm.warp(3 days + 20 minutes);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * (3 days + 20 minutes)
    );
    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 7 days
    );
  }

  function testGetUserRewardsDAIWithMint() external {
    marketDAI.mint(100 ether, address(this));
    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FloatingDeposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 7 days
    );
  }

  function testGetUserRewardsDAIWithTransfer() external {
    marketDAI.deposit(100 ether, address(this));
    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FloatingDeposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    marketDAI.transfer(ALICE, marketDAI.balanceOf(address(this)));

    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    assertEq(
      rewardsController.getUserRewards(assets, operations, ALICE, address(rewardsAsset)),
      emissionPerSecond * 4 days
    );
  }

  function testGetUserRewardsDAIWithTransferFrom() external {
    marketDAI.deposit(100 ether, address(this));
    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FloatingDeposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    marketDAI.approve(address(this), type(uint256).max);
    marketDAI.transferFrom(address(this), ALICE, marketDAI.balanceOf(address(this)));

    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    assertEq(
      rewardsController.getUserRewards(assets, operations, ALICE, address(rewardsAsset)),
      emissionPerSecond * 4 days
    );
  }

  function testGetUserRewardsDAIWithWithdraw() external {
    marketDAI.deposit(100 ether, address(this));
    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FloatingDeposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    marketDAI.withdraw(100 ether, address(this), address(this));

    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
  }

  function testGetUserRewardsDAIWithRedeem() external {
    marketDAI.deposit(100 ether, address(this));
    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FloatingDeposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    marketDAI.redeem(100 ether, address(this), address(this));

    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
  }

  function testGetUserRewardsDAIWithFloatingBorrow() external {
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, address(this));

    marketWETH.deposit(100 ether, address(this));
    auditor.enterMarket(marketWETH);
    marketDAI.borrow(50 ether, address(this), address(this));

    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingBorrow,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FloatingBorrow,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 7 days
    );
  }

  function testGetUserRewardsDAIWithFloatingRefund() external {
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, address(this));

    marketWETH.deposit(100 ether, address(this));
    auditor.enterMarket(marketWETH);
    marketDAI.borrow(50 ether, address(this), address(this));

    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingBorrow,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FloatingBorrow,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    marketDAI.refund(50 ether, address(this));

    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
  }

  function testGetUserRewardsDAIWithFloatingRepay() external {
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, address(this));

    marketWETH.deposit(100 ether, address(this));
    auditor.enterMarket(marketWETH);
    marketDAI.borrow(50 ether, address(this), address(this));

    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingBorrow,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FloatingBorrow,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    marketDAI.repay(marketDAI.previewRefund(50 ether), address(this));

    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
  }

  function testGetUserRewardsDAIWithFixedDeposit() external {
    marketDAI.depositAtMaturity(FixedLib.INTERVAL, 100 ether, 100 ether, address(this));

    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FixedDeposit,
      maturity: FixedLib.INTERVAL
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FixedDeposit,
      FixedLib.INTERVAL,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );

    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 7 days
    );
  }

  function testGetUserRewardsDAIWithFixedBorrow() external {
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, address(this));

    marketWETH.deposit(100 ether, address(this));
    auditor.enterMarket(marketWETH);
    vm.warp(1 days);
    marketDAI.borrowAtMaturity(FixedLib.INTERVAL, 100 ether, 150 ether, address(this), address(this));

    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FixedBorrow,
      maturity: FixedLib.INTERVAL
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FixedBorrow,
      FixedLib.INTERVAL,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 2 days
    );

    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 6 days
    );
  }

  function testGetUserRewardsDAIWithWithdrawAtMaturity() external {
    marketDAI.depositAtMaturity(FixedLib.INTERVAL, 100 ether, 100 ether, address(this));

    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FixedDeposit,
      maturity: FixedLib.INTERVAL
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FixedDeposit,
      FixedLib.INTERVAL,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    marketDAI.withdrawAtMaturity(FixedLib.INTERVAL, 100 ether, 0, address(this), address(this));

    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
  }

  function testGetUserRewardsDAIWithRepayAtMaturity() external {
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, address(this));

    marketWETH.deposit(100 ether, address(this));
    auditor.enterMarket(marketWETH);
    vm.warp(1 days);
    marketDAI.borrowAtMaturity(FixedLib.INTERVAL, 100 ether, 150 ether, address(this), address(this));

    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FixedBorrow,
      maturity: FixedLib.INTERVAL
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FixedBorrow,
      FixedLib.INTERVAL,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 2 days
    );
    (uint256 principal, uint256 fee) = marketDAI.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    marketDAI.repayAtMaturity(FixedLib.INTERVAL, principal + fee, principal + fee, address(this));

    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 2 days
    );
  }

  function testGetUserRewardsDAIWithAnotherUserInPool() external {
    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FloatingDeposit,
      0,
      address(rewardsAsset)
    );

    marketDAI.deposit(100 ether, address(this));
    vm.warp(5 days);
    vm.prank(ALICE);
    marketDAI.deposit(100 ether, ALICE);

    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 5 days
    );
    assertEq(rewardsController.getUserRewards(assets, operations, ALICE, address(rewardsAsset)), 0);

    vm.warp(7.5 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 5 days + (emissionPerSecond * 2.5 days) / 2
    );
    assertEq(
      rewardsController.getUserRewards(assets, operations, ALICE, address(rewardsAsset)),
      (emissionPerSecond * 2.5 days) / 2
    );
  }

  function testGetUserRewardsWETH() external {
    marketWETH.deposit(1 ether, address(this));
    address[] memory assets = new address[](1);
    assets[0] = address(marketWETH);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , ) = rewardsController.getRewardsData(
      address(marketWETH),
      RewardsController.Operation.FloatingDeposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(3 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 3 days
    );
    vm.warp(3 days + 20 minutes);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * (3 days + 20 minutes)
    );
    vm.warp(7 days);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * 7 days
    );
  }

  function testClaimAllRewardsToSelf() external {
    marketDAI.deposit(100 ether, address(this));
    marketWETH.deposit(10 ether, address(this));
    address[] memory assets = new address[](2);
    assets[0] = address(marketDAI);
    assets[1] = address(marketWETH);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0
    });

    vm.warp(4 days + 20 minutes);
    uint256 rewardsToBeClaimed = rewardsController.getUserRewards(
      assets,
      operations,
      address(this),
      address(rewardsAsset)
    );
    rewardsController.claimAllRewardsToSelf(assets, operations);

    assertEq(rewardsAsset.balanceOf(address(this)), rewardsToBeClaimed);
    assertEq(rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)), 0);
  }

  function testDistributionEnd() external {
    marketDAI.deposit(100 ether, address(this));
    marketWETH.deposit(10 ether, address(this));

    address[] memory assets = new address[](1);
    assets[0] = address(marketDAI);
    RewardsController.OperationData[] memory operations = new RewardsController.OperationData[](1);
    operations[0] = RewardsController.OperationData({
      operation: RewardsController.Operation.FloatingDeposit,
      maturity: 0
    });
    (, uint256 emissionPerSecond, , uint256 distributionEnd) = rewardsController.getRewardsData(
      address(marketDAI),
      RewardsController.Operation.FloatingDeposit,
      0,
      address(rewardsAsset)
    );

    vm.warp(distributionEnd);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * distributionEnd
    );

    vm.warp(distributionEnd + 4 days + 20 minutes);
    assertEq(
      rewardsController.getUserRewards(assets, operations, address(this), address(rewardsAsset)),
      emissionPerSecond * distributionEnd
    );
  }
}
