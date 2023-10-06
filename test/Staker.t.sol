// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ForkTest, stdError } from "./Fork.t.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
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
import { EXA, EscrowedEXA, ISablierV2LockupLinear } from "../contracts/periphery/EscrowedEXA.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

// solhint-disable reentrancy
contract StakerTest is ForkTest {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint80;

  uint256 internal constant BOB_KEY = 0xb0b;
  address payable internal bob;
  uint256 internal shareValue;
  uint256 internal votes;
  Balances internal b;

  WETH internal weth;
  ERC20 internal op;
  ERC20 internal exa;
  ERC20 internal esEXA;
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
  IRouter internal constant router = IRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);

  function setUp() external _setUp {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 107_709_211);

    op = ERC20(deployment("OP"));
    exa = ERC20(deployment("EXA"));
    weth = WETH(payable(deployment("WETH")));
    esEXA = ERC20(
      address(
        EscrowedEXA(
          address(
            new ERC1967Proxy(
              address(new EscrowedEXA(EXA(address(exa)), ISablierV2LockupLinear(deployment("SablierV2LockupLinear")))),
              abi.encodeCall(EscrowedEXA.initialize, (6 * 4 weeks, 1e17))
            )
          )
        )
      )
    );
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
          address(new Staker(exa, weth, esEXA, voter, auditor, factory, votingEscrow, rewardsController)),
          abi.encodeCall(Staker.initialize, ())
        )
      )
    );
    vm.label(address(staker), "Staker");
    EscrowedEXA escrowedEXA = EscrowedEXA(address(esEXA));
    escrowedEXA.grantRole(escrowedEXA.REDEEMER_ROLE(), address(staker));
    escrowedEXA.grantRole(escrowedEXA.TRANSFERRER_ROLE(), address(staker));
    escrowedEXA.grantRole(escrowedEXA.TRANSFERRER_ROLE(), address(rewardsController));

    bob = payable(vm.addr(BOB_KEY));
    vm.label(bob, "bob");
    deal(address(velo), bob, 500e18);
    deal(address(marketUSDC.asset()), address(this), 5_000_000e6);

    vm.startPrank(deployment("TimelockController"));
    exa.transfer(address(this), 5_000_000e18);
    exa.transfer(bob, 2_000_000e18);
    vm.stopPrank();

    exa.approve(address(router), type(uint256).max);
    exa.approve(address(staker), type(uint256).max);
    exa.approve(address(esEXA), type(uint256).max);
    pool.approve(address(staker), type(uint256).max);
    weth.approve(address(router), type(uint256).max);
    esEXA.approve(address(staker), type(uint256).max);

    EscrowedEXA(address(esEXA)).mint(2_000_000e18, address(this));
    EscrowedEXA(address(esEXA)).mint(100_000e18, address(rewardsController));

    marketUSDC.asset().approve(address(marketUSDC), type(uint256).max);
    marketUSDC.deposit(5_000_000e6, bob);
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

    targetSender(address(this));
    targetContract(address(this));
    bytes4[] memory selectors = new bytes4[](10);
    selectors[0] = this.stakeETH.selector;
    selectors[1] = this.stakeBalance.selector;
    selectors[2] = this.stakeRewards.selector;
    selectors[3] = this.mint.selector;
    selectors[4] = this.deposit.selector;
    selectors[5] = this.unstake.selector;
    selectors[6] = this.redeem.selector;
    selectors[7] = this.withdraw.selector;
    selectors[8] = this.harvest.selector;
    selectors[9] = this.distribute.selector;
    targetSelector(FuzzSelector(address(this), selectors));
  }

  function invariantShareValue() external {
    uint256 currentShareValue = staker.previewMint(1e18);
    assertGe(currentShareValue, shareValue, "share value decreased");
    shareValue = currentShareValue;
  }

  function invariantVotes() external {
    uint256 id = staker.lockId();
    if (id != 0) {
      uint256 currentVotes = voter.votes(id, pool);
      assertGe(currentVotes, votes, "votes decreased");
      votes = currentVotes;
    }
  }

  function invariantStakerAssets() external {
    (uint256 reserveEXA, uint256 reserveWETH, ) = pool.getReserves();
    Market[] memory markets = auditor.allMarkets();

    for (uint256 i = 0; i < markets.length; ++i) {
      assertEq(markets[i].balanceOf(address(staker)), 0, "0 staker market");
      assertEq(markets[i].asset().balanceOf(address(staker)), 0, "0 staker asset");
      if (staker.lockId() != 0) assertEq(markets[i].balanceOf(markets[i].treasury()), 0, "0 treasury");
    }
    assertEq(address(staker).balance, 0, "0 staker eth");
    assertEq(gauge.earned(staker), 0, "0 staker emission");
    assertEq(staker.distributor().claimable(staker.lockId()), 0, "0 staker rebase");
    assertEq(pool.balanceOf(address(staker)), 0, "0 staker lp");
    assertEq(velo.balanceOf(address(staker)), 0, "0 staker velo");
    assertEq(exa.balanceOf(address(pool)), reserveEXA, "pool exa");
    assertEq(weth.balanceOf(address(pool)), reserveWETH, "pool weth");
  }

  function invariantEscrowedRatio() external {
    uint256 ratio = staker.escrowedRatio(address(this));
    assertLe(ratio, 1e18, "escrowed ratio > 1");
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
        staker.stakeBalance{ value: 0.1 ether }(bob, uint256(0.1 ether).mulDivDown(reserveEXA, reserveWETH), 0, 0, 0);
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

  function testStakeRedeemWithdrawDepositMint() external {
    staker.stakeETH{ value: 1 ether }(payable(address(this)), 0, 0);
    skip(1 minutes);

    uint256 shares = staker.balanceOf(address(this)) / 2;
    uint256 previewRedeem = staker.previewRedeem(shares);
    assertEq(previewRedeem, staker.redeem(shares, address(this), address(this)), "redeem != preview redeem");
    assertEq(previewRedeem, pool.balanceOf(address(this)), "preview redeem != pool balance");

    uint256 assets = staker.convertToAssets(staker.balanceOf(address(this)));
    staker.withdraw(assets, address(this), address(this));
    assertEq(staker.balanceOf(address(this)), 0, "shares > 0");
    assertEq(assets + previewRedeem, pool.balanceOf(address(this)), "assets + previewRedeem != pool balance");

    pool.approve(address(staker), type(uint256).max);
    staker.deposit(pool.balanceOf(address(this)) / 2, address(this));
    staker.mint(staker.convertToShares(pool.balanceOf(address(this))), address(this));
    assertApproxEqAbs(pool.balanceOf(address(this)), 0, 1e10, "pool balance");
  }

  function testStakeEXAPartiallyEscrowed() external {
    uint256 amountEXA = 100e18;
    uint256 amountesEXA = 900e18;
    uint256 amountETH = staker.previewETH(amountEXA + amountesEXA);

    staker.stakeBalance{ value: amountETH }(payable(address(this)), amountEXA, amountesEXA, 0, 0);
    assertGt(staker.balanceOf(address(this)), 0, "staker shares == 0");
    assertApproxEqAbs(staker.escrowedRatio(address(this)), 0.9e18, 1, "escrowed != 90%");
  }

  function testUnstakePartiallyEscrowed() external {
    uint256 amountEXA = 100e18;
    uint256 amountesEXA = 10e18;
    uint256 ratio = amountesEXA.mulDivDown(1e18, amountEXA + amountesEXA);
    uint256 amountETH = staker.previewETH(amountEXA + amountesEXA);

    staker.stakeBalance{ value: amountETH }(payable(address(this)), amountEXA, amountesEXA, 0, 0);
    uint256 shares = staker.balanceOf(address(this));
    assertGt(shares, 0, "staker shares > 0");
    assertApproxEqAbs(staker.escrowedRatio(address(this)), ratio, 1, "escrowed ratio");

    uint256 exaBalance = exa.balanceOf(address(this));
    uint256 esEXABalance = esEXA.balanceOf(address(this));
    uint256 unstakePercentage = 0.5e18;
    staker.unstake(address(this), unstakePercentage);

    uint256 unstakedEXA = exa.balanceOf(address(this)) - exaBalance;
    uint256 unstakedesEXA = esEXA.balanceOf(address(this)) - esEXABalance;
    uint256 totalUnstaked = unstakedEXA + unstakedesEXA;
    assertApproxEqAbs(unstakedEXA.mulDivDown(1e18, totalUnstaked), 1e18 - ratio, 1, "unstaked exa ratio");
    assertApproxEqAbs(unstakedesEXA.mulDivDown(1e18, totalUnstaked), ratio, 2, "unstaked esEXA ratio");

    assertApproxEqAbs(staker.balanceOf(address(this)), shares.mulWadDown(unstakePercentage), 1, "unstaked shares");
    assertApproxEqAbs(staker.escrowedRatio(address(this)), ratio, 1, "escrowed ratio changed");
  }

  function testUnstakeSomeonelse() external {
    staker.stakeBalance{ value: 1 ether }(payable(address(this)), 100e18, 0, 0, 0);
    vm.expectRevert(bytes(""));
    vm.prank(bob);
    staker.unstake(address(this), 1e18);
  }

  function testStakeMultipleRewards() external {
    RewardsController.Config[] memory configs = new RewardsController.Config[](2);
    configs[0] = RewardsController.Config({
      market: marketUSDC,
      reward: exa,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 20_000e6,
      totalDistribution: 40_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.5e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    configs[1] = RewardsController.Config({
      market: marketUSDC,
      reward: esEXA,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 20_000e6,
      totalDistribution: 10_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.5e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });

    vm.prank(deployment("TimelockController"));
    rewardsController.config(configs);

    skip(1 days);

    ERC20[] memory assets = new ERC20[](2);
    assets[0] = exa;
    assets[1] = esEXA;
    uint256 balanceBefore = staker.balanceOf(bob);

    staker.stakeRewards{ value: 1e18 }(claimPermit(assets), 0, 0);

    assertGt(staker.balanceOf(bob), balanceBefore, "bob shares should grow");
  }

  function balances() internal {
    b.eth = address(this).balance;
    b.exa = exa.balanceOf(address(this));
    b.pool = pool.balanceOf(address(this));
    b.esEXA = esEXA.balanceOf(address(this));
    b.staker = staker.balanceOf(address(this));
    b.assets = staker.maxWithdraw(address(this)); // todo: include it in invariants and asserts
    b.poolGauge = pool.balanceOf(address(gauge));
    b.escrowedRatio = staker.escrowedRatio(address(this));
  }

  struct StakeVars {
    uint256 reserveEXA;
    uint256 reserveWETH;
    uint256 swapWETH;
    uint256 outEXA;
    uint256 previewShares;
    uint256 newesRatio;
    uint256 shares;
    uint256 assets;
    uint256 exa;
  }

  function stakeBalance(uint256 eth, uint80 inEXA, uint80 inesEXA, uint80 minEXA, uint72 keepETH) external context {
    eth = _bound(eth, 1e5, type(uint72).max);
    keepETH = uint72(_bound(keepETH, 0, eth));
    StakeVars memory vars;
    vars.exa = inEXA + inesEXA;
    (vars.reserveEXA, vars.reserveWETH, ) = pool.getReserves();
    uint256 previewETH = vars.exa.mulDivDown(vars.reserveWETH, vars.reserveEXA);
    if (
      eth > keepETH &&
      eth >= previewETH &&
      vars.exa < uint256(eth - keepETH).mulDivDown(vars.reserveEXA, vars.reserveWETH)
    ) {
      vars.swapWETH = uint256((eth - keepETH - vars.exa.mulDivDown(vars.reserveWETH, vars.reserveEXA)) / 2).mulDivDown(
        1e4 - factory.getFee(pool, false),
        1e4
      );
      vars.outEXA = vars.swapWETH.mulDivDown(vars.reserveEXA, vars.swapWETH + vars.reserveWETH).mulDivDown(
        1e4 - factory.getFee(pool, false),
        1e4
      );

      if (vars.outEXA + vars.exa >= minEXA && (eth - keepETH) < 4) {
        vm.expectRevert(InsufficientOutputAmount.selector);
      } else {
        // FIXME
        vars.previewShares = staker.previewDeposit(
          Math.min(
            ((vars.outEXA + vars.exa) * pool.totalSupply()) / (vars.reserveEXA - vars.outEXA),
            ((eth - keepETH - vars.swapWETH) * pool.totalSupply()) /
              (vars.reserveWETH + vars.swapWETH.mulWadDown(0.99e18))
          )
        );
      }
    }
    staker.stakeBalance{ value: eth }(payable(address(this)), inEXA, inesEXA, minEXA, keepETH);
    if (eth - keepETH < previewETH || keepETH == eth) {
      assertEq(address(this).balance, b.eth, "eth balance changed");
      assertEq(staker.balanceOf(address(this)), b.staker, "shares balance changed");
      assertEq(pool.balanceOf(address(gauge)), b.poolGauge, "pool gauge balance changed");
      assertEq(exa.balanceOf(address(this)), b.exa, "exa balance changed");
      assertEq(esEXA.balanceOf(address(this)), b.esEXA, "esEXA balance changed");
      assertEq(staker.escrowedRatio(address(this)), b.escrowedRatio, "escrowed ratio changed");
    } else {
      vars.newesRatio = inesEXA.mulDivDown(1e18, vars.exa + vars.outEXA);

      assertEq(address(this).balance, b.eth + keepETH - eth, "eth balance");
      assertEq(exa.balanceOf(address(this)), b.exa - inEXA, "exa balance");
      assertEq(esEXA.balanceOf(address(this)), b.esEXA - inesEXA, "esEXA balance");

      assertApproxEqAbs(staker.balanceOf(address(this)), b.staker + vars.previewShares, 1_000, "shares");

      vars.assets = staker.maxWithdraw(address(this));
      // FIXME
      assertApproxEqAbs(
        staker.escrowedRatio(address(this)),
        (b.assets.mulWadDown(b.escrowedRatio) + (vars.assets - b.assets).mulWadDown(vars.newesRatio)).divWadDown(
          vars.assets
        ),
        1_000,
        "final escrowed ratio"
      );
    }
    assertEq(pool.balanceOf(address(this)), b.pool, "pool balance");
  }

  function stakeRewards(uint256 eth, uint80 minEXA, uint72 keepETH) external context {
    eth = _bound(eth, 1e5, type(uint72).max);
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    staker.stakeRewards{ value: eth }(claimPermit(assets), minEXA, keepETH);
  }

  function stakeRewards2(uint256 eth, uint80 minEXA, uint72 keepETH, uint256 rewards) external context {
    eth = _bound(eth, 1e5, type(uint72).max);
    rewards = _bound(rewards, 0, 2);

    ERC20[] memory assets = new ERC20[](rewards);
    ERC20[] memory possibleAssets = new ERC20[](3);
    possibleAssets[0] = exa;
    possibleAssets[1] = esEXA;
    possibleAssets[2] = ERC20(new MockERC20("Random token", "RNT", 18));

    for (uint256 i = 0; i < rewards; ++i) {
      // get a pseudo random number - https://github.com/foundry-rs/foundry/issues/5407
      assets[i] = possibleAssets[i];
    }

    uint256 claimableEXA = rewardsController.allClaimable(bob, exa);
    uint256 claimableesEXA = rewardsController.allClaimable(bob, esEXA);

    // if 
    // (rewards length >= 1 & <= 2 
    // && doesn't contain a random token
    // && claimableEXA > 0 || claimableesEXA > 0)
    // then it should stake -> assertGt(newBalance, oldBalance)


  }

  function stakeETH(uint256 eth, uint80 minEXA, uint72 keepETH) external context {
    eth = _bound(eth, 1e5, type(uint72).max);
    uint256 swapWETH;
    uint256 outEXA;
    uint256 previewShares;

    if (eth > keepETH) {
      (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
      {
        (uint256 reserveEXA, uint256 reserveWETH) = address(exa) < address(weth)
          ? (reserve0, reserve1)
          : (reserve1, reserve0);
        swapWETH = uint256((eth - keepETH) / 2).mulDivDown(1e4 - factory.getFee(pool, false), 1e4);
        outEXA = swapWETH.mulDivDown(reserveEXA, swapWETH + reserveWETH).mulDivDown(
          1e4 - factory.getFee(pool, false),
          1e4
        );
      }

      if (outEXA >= minEXA && (eth - keepETH) < 4) {
        vm.expectRevert(InsufficientOutputAmount.selector);
      } else {
        previewShares = Math.min(
          (outEXA * pool.totalSupply()) / (reserve0 - outEXA),
          ((eth - keepETH - swapWETH) * pool.totalSupply()) / (reserve1 + swapWETH.mulWadDown(0.99e18))
        );
        previewShares = staker.previewDeposit(previewShares);
      }
    }
    staker.stakeETH{ value: eth }(payable(address(this)), minEXA, keepETH);
    if (keepETH >= eth || (minEXA > outEXA) || (outEXA >= minEXA && (eth - keepETH) < 4)) {
      assertEq(address(this).balance, b.eth, "eth balance changed");
      assertEq(staker.balanceOf(address(this)), b.staker, "shares balance changed");
      assertEq(pool.balanceOf(address(gauge)), b.poolGauge, "pool gauge balance changed");
    } else {
      assertEq(address(this).balance, b.eth + keepETH - eth, "eth used");
      assertApproxEqAbs(staker.balanceOf(address(this)), b.staker + previewShares, 35, "shares balance");
    }
    assertEq(exa.balanceOf(address(this)), b.exa, "exa balance");
    assertEq(pool.balanceOf(address(this)), b.pool, "pool balance");
    assertEq(esEXA.balanceOf(address(this)), b.esEXA, "esEXA balance");
  }

  function unstake(uint64 percentage) external context {
    uint256 shares = staker.balanceOf(address(this));
    if (percentage == 0) vm.expectRevert(stdError.assertionError);
    else if (
      (staker.previewRedeem(shares.mulWadDown(percentage) * exa.balanceOf(address(pool))) / pool.totalSupply()) == 0 ||
      (staker.previewRedeem(shares.mulWadDown(percentage) * weth.balanceOf(address(pool))) / pool.totalSupply()) == 0
    ) {
      vm.expectRevert(InsufficientLiquidityBurned.selector);
    } else if (percentage > 1e18) vm.expectRevert(bytes(""));

    staker.unstake(address(this), percentage);
    assertEq(b.escrowedRatio, staker.escrowedRatio(address(this)), "escrowed ratio changed");
  }

  function mint(uint256 eth) external context {
    eth = _bound(eth, 1e10, type(uint64).max);
    weth.deposit{ value: eth }();
    (, , uint256 liquidity) = router.addLiquidity(
      exa,
      weth,
      false,
      exa.balanceOf(address(this)),
      eth,
      0,
      0,
      address(this),
      block.timestamp + 1 days
    );
    uint256 assets = staker.convertToShares(liquidity);
    if (assets == 0) vm.expectRevert(ZeroAmount.selector);
    staker.mint(assets, address(this));
  }

  function deposit(uint256 eth) external context {
    eth = _bound(eth, 1e10, type(uint64).max);
    weth.deposit{ value: eth }();
    (, , uint256 liquidity) = router.addLiquidity(
      exa,
      weth,
      false,
      exa.balanceOf(address(this)),
      eth,
      0,
      0,
      address(this),
      block.timestamp + 1 days
    );
    staker.deposit(liquidity, address(this));
  }

  function redeem(uint96 shares) external context {
    uint256 previewAssets = staker.previewRedeem(shares);
    if (shares > staker.balanceOf(address(this))) vm.expectRevert(bytes(""));
    uint256 assets = staker.redeem(shares, address(this), address(this));
    if (assets > 0) {
      assertEq(assets, previewAssets, "preview redeem == redeem");
      assertEq(pool.balanceOf(address(this)), b.pool + assets, "pool balance += assets redeem");
    }
  }

  function withdraw(uint96 assets) external context {
    uint256 previewShares = staker.previewWithdraw(assets);
    if (assets > staker.convertToAssets(staker.balanceOf(address(this)))) vm.expectRevert(bytes(""));
    uint256 shares = staker.withdraw(assets, address(this), address(this));
    if (shares > 0) {
      assertEq(shares, previewShares, "preview withdraw == withdraw");
      assertEq(pool.balanceOf(address(this)), b.pool + assets, "pool balance += assets withdraw");
    }
  }

  function harvest() external context {
    staker.harvest();
  }

  function distribute() external context {
    IGauge[] memory gauges = new IGauge[](1);
    gauges[0] = gauge;
    voter.distribute(gauges);
  }

  function warp(uint32 time) external {
    skip(_bound(time, 1, type(uint32).max));
    _lastTimestamp = block.timestamp;
  }

  uint256 internal _lastTimestamp;
  modifier context() {
    vm.warp(_lastTimestamp);
    balances();
    _;
    _lastTimestamp = block.timestamp;
  }

  modifier _setUp() {
    _;
    _lastTimestamp = block.timestamp;
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

error ZeroAmount();
error InsufficientOutputAmount();
error InsufficientLiquidityBurned();

struct Balances {
  uint256 eth;
  uint256 exa;
  uint256 pool;
  uint256 esEXA;
  uint256 staker;
  uint256 assets;
  uint256 poolGauge;
  uint256 escrowedRatio;
}

interface IRouter {
  function addLiquidity(
    ERC20 tokenA,
    ERC20 tokenB,
    bool stable,
    uint256 amountADesired,
    uint256 amountBDesired,
    uint256 amountAMin,
    uint256 amountBMin,
    address to,
    uint256 deadline
  ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

enum DepositType {
  DEPOSIT_FOR_TYPE,
  CREATE_LOCK_TYPE,
  INCREASE_LOCK_AMOUNT,
  INCREASE_UNLOCK_TIME
}
