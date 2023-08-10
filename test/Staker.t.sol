// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ForkTest } from "./Fork.t.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITransparentUpgradeableProxy, ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { RewardsController, Auditor, Market, ClaimPermit } from "../contracts/RewardsController.sol";
import {
  WETH,
  ERC20,
  IPool,
  IGauge,
  IVoter,
  Staker,
  Permit,
  IReward,
  IERC20Permit,
  IPoolFactory,
  IVotingEscrow,
  LockedBalance,
  FixedPointMathLib
} from "../contracts/Staker.sol";

// solhint-disable reentrancy
contract StakerTest is ForkTest {
  using FixedPointMathLib for uint256;

  uint256 internal constant BOB_KEY = 0xb0b;
  address payable internal bob;

  WETH internal weth;
  ERC20 internal op;
  ERC20 internal exa;
  ERC20 internal velo;
  IPool internal pool;
  IGauge internal gauge;
  IVoter internal voter;
  Staker internal staker;
  Market internal marketUSDC;
  Auditor internal auditor;
  IPoolFactory internal factory;
  IVotingEscrow internal votingEscrow;
  RewardsController internal rewardsController;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 107_709_211);

    op = ERC20(deployment("OP"));
    exa = ERC20(deployment("EXA"));
    weth = WETH(payable(deployment("WETH")));
    velo = ERC20(deployment("VELO"));
    pool = IPool(deployment("EXAPool"));
    gauge = IGauge(deployment("EXAGauge"));
    voter = IVoter(deployment("VelodromeVoter"));
    auditor = Auditor(deployment("Auditor"));
    factory = IPoolFactory(deployment("VelodromePoolFactory"));
    marketUSDC = Market(deployment("MarketUSDC"));
    votingEscrow = IVotingEscrow(deployment("VelodromeVotingEscrow"));
    rewardsController = RewardsController(deployment("RewardsController"));
    vm.label(address(gauge.feesVotingReward()), "EXAFees");
    vm.label(address(voter.gaugeToBribe(gauge)), "EXABribes");

    vm.startPrank(deployment("ProxyAdmin"));
    ITransparentUpgradeableProxy(payable(address(rewardsController))).upgradeTo(address(new RewardsController()));
    vm.stopPrank();

    staker = Staker(
      payable(
        new ERC1967Proxy(
          address(new Staker(exa, weth, voter, auditor, factory, votingEscrow, rewardsController)),
          abi.encodeCall(Staker.initialize, ())
        )
      )
    );
    vm.label(address(staker), "Staker");

    bob = payable(vm.addr(BOB_KEY));
    vm.label(bob, "bob");
    deal(address(exa), bob, 2_000_000e18);
    deal(address(velo), bob, 500e18);
    deal(address(marketUSDC.asset()), address(this), 100_000e6);
    marketUSDC.asset().approve(address(marketUSDC), type(uint256).max);
    marketUSDC.deposit(100_000e6, bob);
    bob.transfer(500 ether);

    vm.label(address(voter.minter()), "VELOMinter");
    vm.label(address(voter.minter().rewardsDistributor()), "VELODistributor");
    vm.label(address(factory.getPool(op, weth, false)), "OPPool");
    vm.label(factory.getPool(op, weth, false).poolFees(), "OPPoolFees");
    vm.label(factory.getPool(exa, weth, false).poolFees(), "EXAPoolFees");
    deal(address(op), address(this), 100_000e18);
    IReward bribes = voter.gaugeToBribe(gauge);
    op.approve(address(bribes), type(uint256).max);
    bribes.notifyRewardAmount(op, 10_000e18);

    vm.label(marketUSDC.treasury(), "treasury");
    Market[] memory markets = auditor.allMarkets();
    for (uint256 i = 0; i < markets.length; ++i) {
      vm.label(address(markets[i].asset()), markets[i].asset().symbol());
      vm.label(address(markets[i]), string.concat("Market", markets[i].asset().symbol()));
      vm.prank(markets[i].treasury());
      markets[i].approve(address(staker), type(uint256).max);
    }
  }

  function testStakerProtoSimulator() external {
    {
      address treasury = marketUSDC.treasury();
      vm.startPrank(treasury);
      gauge.withdraw(gauge.balanceOf(treasury));
      pool.approve(address(staker), type(uint256).max);
      staker.deposit(pool.balanceOf(treasury), treasury);
    }
    {
      address beefy = 0x5aaC0A5039c8D0CA985829A8a4De3d1020B36298;
      vm.startPrank(beefy);
      gauge.withdraw(gauge.balanceOf(beefy));
      pool.approve(address(staker), type(uint256).max);
      staker.deposit(pool.balanceOf(beefy), address(this));
    }
    vm.startPrank(deployment("TimelockController"));
    exa.transfer(address(staker), 1_000_000e18);
    deal(address(velo), address(staker), 1e18);
    staker.harvest();

    vm.startPrank(bob);
    exa.approve(address(staker), type(uint256).max);
    for (uint256 i = 0; i < uint256(365 days) / 1 weeks; ++i) {
      skip(1 hours + 1 minutes);
      {
        IGauge[] memory gauges = new IGauge[](1);
        gauges[0] = gauge;
        voter.distribute(gauges);
      }
      rewind(1 hours + 1 minutes);
      for (uint256 j = 0; j < 10; ++j) {
        skip(1 weeks / 10);
        uint256 reserveEXA;
        uint256 reserveWETH;
        {
          (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
          (reserveEXA, reserveWETH) = address(exa) < address(weth) ? (reserve0, reserve1) : (reserve1, reserve0);
        }
        staker.stakeBalance{ value: 0.1 ether }(bob, uint256(0.1 ether).mulDivDown(reserveEXA, reserveWETH), 0, 0);
      }
    }
  }

  function testStakeManyTimesAndUnstake() external checks {
    uint256 amountEXA = 100e18;
    uint256 amountETH = staker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);
    uint256 poolWeight = voter.weights(pool);

    vm.prank(bob);
    payable(this).transfer(amountETH);
    staker.stakeBalance{ value: amountETH }(permit(exa, amountEXA), 0, 0);

    assertEq(bob.balance, balanceETH - amountETH, "user eth");
    assertEq(exa.balanceOf(bob), balanceEXA - amountEXA, "user exa");
    assertEq(gauge.balanceOf(bob), 0, "user gauge");
    assertGt(gauge.balanceOf(address(staker)), 0, "staker gauge");
    LockedBalance memory locked = votingEscrow.locked(staker.lockId());
    assertEq(locked.amount, 0, "not locked yet");
    assertEq(locked.end, 0, "not locked yet");
    assertEq(locked.isPermanent, false, "not locked yet");
    check();
    staker.harvest();

    skip(1 days);
    {
      IGauge[] memory gauges = new IGauge[](1);
      gauges[0] = gauge;
      voter.distribute(gauges);
    }
    uint256 earnedVELO = gauge.earned(staker);
    assertGt(earnedVELO, 0, "earned velo");
    staker.stakeETH{ value: amountETH }(bob, 0, 0);
    locked = votingEscrow.locked(staker.lockId());
    assertEq(locked.amount, int256(earnedVELO), "initial locked velo");
    assertEq(locked.isPermanent, true, "permanent lock");
    assertEq(voter.usedWeights(staker.lockId()), earnedVELO, "staker votes");
    assertEq(voter.weights(pool), earnedVELO + poolWeight, "pool weight");
    poolWeight += earnedVELO;
    check();

    skip(1 hours);
    uint256 epoch = block.timestamp - (block.timestamp % 1 weeks);
    uint256 newVELO = gauge.earned(staker);
    assertGt(newVELO, 0, "earned new velo");
    staker.stakeETH{ value: amountETH }(bob, 0, 0);
    assertEq(voter.usedWeights(staker.lockId()), earnedVELO += newVELO, "new votes");
    assertEq(voter.weights(pool), newVELO + poolWeight, "new weight");
    poolWeight += newVELO;
    check();

    skip(1 hours);
    newVELO = gauge.earned(staker);
    assertGt(newVELO, 0, "earned new velo");
    assertEq(block.timestamp - (block.timestamp % 1 weeks), epoch, "same epoch vote");
    staker.stakeETH{ value: amountETH }(bob, 0, 0);
    assertEq(voter.usedWeights(staker.lockId()), earnedVELO += newVELO, "more new votes");
    assertEq(voter.weights(pool), newVELO + poolWeight, "more new weight");
    poolWeight += newVELO;
    check();

    skip(1 weeks);
    assertEq(block.timestamp - (block.timestamp % 1 weeks), epoch + 1 weeks, "next epoch");
    {
      IGauge[] memory gauges = new IGauge[](1);
      gauges[0] = gauge;
      voter.distribute(gauges);
    }
    staker.harvest();
    assertEq(weth.balanceOf(address(staker)), 0, "no weth");
    assertEq(velo.balanceOf(address(staker)), 0, "no velo");
    assertEq(op.balanceOf(address(staker)), 0, "no op");

    vm.prank(bob);
    staker.approve(address(this), type(uint256).max);
    staker.unstake(bob, 1e18);
    assertEq(staker.totalSupply(), 0, "no shares");
  }

  function testDonateVELO() external checks {
    uint256 balanceVELO = velo.balanceOf(bob);

    vm.startPrank(bob);
    velo.transfer(address(staker), 100e18);
    staker.harvest();
    vm.stopPrank();

    assertEq(velo.balanceOf(bob), balanceVELO - 100e18, "velo balance");
  }

  modifier checks() {
    Market[] memory markets = auditor.allMarkets(); // force market updates
    for (uint256 i = 0; i < markets.length; ++i) markets[i].borrow(0, address(420), address(69));
    _;
    check();
  }

  function check() internal {
    assertEq(address(staker).balance, 0, "0 staker eth");
    assertEq(pool.balanceOf(address(staker)), 0, "0 staker lp");
    assertEq(weth.balanceOf(address(staker)), 0, "0 staker weth");
    assertEq(velo.balanceOf(address(staker)), 0, "0 staker velo");
    assertEq(gauge.earned(staker), 0, "0 staker emission");
    assertEq(staker.distributor().claimable(staker.lockId()), 0, "0 staker rebase");

    Market[] memory markets = auditor.allMarkets();
    for (uint256 i = 0; i < markets.length; ++i) assertEq(markets[i].balanceOf(markets[i].treasury()), 0, "0 treasury");

    uint256 reserveEXA;
    uint256 reserveWETH;
    {
      (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
      (reserveEXA, reserveWETH) = address(exa) < address(weth) ? (reserve0, reserve1) : (reserve1, reserve0);
    }
    assertEq(exa.balanceOf(address(pool)), reserveEXA, "pool exa");
    assertEq(weth.balanceOf(address(pool)), reserveWETH, "pool weth");
  }

  function permit(ERC20 asset, uint256 value) internal view returns (Permit memory p) {
    p = Permit(bob, value, block.timestamp, 0, bytes32(0), bytes32(0));
    (p.v, p.r, p.s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          asset.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              p.owner,
              staker,
              p.value,
              asset.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
  }

  function claimPermit(ERC20[] memory assets) internal view returns (ClaimPermit memory p) {
    p = ClaimPermit(bob, assets, block.timestamp, 0, bytes32(0), bytes32(0));
    (p.v, p.r, p.s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          rewardsController.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("ClaimPermit(address owner,address spender,address[] assets,uint256 deadline)"),
              bob,
              staker,
              assets,
              rewardsController.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
  }

  // solhint-disable-next-line no-empty-blocks
  receive() external payable {}

  event Deposit(address indexed from, uint256 indexed tokenId, uint256 amount);
  event Withdraw(address indexed from, uint256 indexed tokenId, uint256 amount);
  event LockPermanent(address indexed owner, uint256 indexed tokenId, uint256 amount, uint256 ts);
  event Abstained(
    address indexed voter,
    address indexed pool,
    uint256 indexed tokenId,
    uint256 weight,
    uint256 totalWeight,
    uint256 timestamp
  );
  event Voted(
    address indexed voter,
    address indexed pool,
    uint256 indexed tokenId,
    uint256 weight,
    uint256 totalWeight,
    uint256 timestamp
  );
  event Deposit(
    address indexed provider,
    uint256 indexed tokenId,
    DepositType indexed depositType,
    uint256 value,
    uint256 locktime,
    uint256 ts
  );
}

enum DepositType {
  DEPOSIT_FOR_TYPE,
  CREATE_LOCK_TYPE,
  INCREASE_LOCK_AMOUNT,
  INCREASE_UNLOCK_TIME
}
