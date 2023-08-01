// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ForkTest } from "./Fork.t.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITransparentUpgradeableProxy, ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { RewardsController, ClaimPermit, Market } from "../contracts/RewardsController.sol";
import {
  WETH,
  ERC20,
  IPool,
  IGauge,
  IVoter,
  Staker,
  Permit,
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
  ERC20 internal exa;
  ERC20 internal velo;
  IPool internal pool;
  IGauge internal gauge;
  IVoter internal voter;
  Staker internal staker;
  Market internal marketUSDC;
  IPoolFactory internal factory;
  IVotingEscrow internal votingEscrow;
  RewardsController internal rewardsController;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 107_618_399);

    exa = ERC20(deployment("EXA"));
    weth = WETH(payable(deployment("WETH")));
    velo = ERC20(deployment("VELO"));
    pool = IPool(deployment("EXAPool"));
    gauge = IGauge(deployment("EXAGauge"));
    voter = IVoter(deployment("VelodromeVoter"));
    factory = IPoolFactory(deployment("VelodromePoolFactory"));
    marketUSDC = Market(deployment("MarketUSDC"));
    votingEscrow = IVotingEscrow(deployment("VelodromeVotingEscrow"));
    rewardsController = RewardsController(deployment("RewardsController"));

    vm.startPrank(deployment("ProxyAdmin"));
    ITransparentUpgradeableProxy(payable(address(rewardsController))).upgradeTo(address(new RewardsController()));
    vm.stopPrank();

    staker = Staker(
      payable(
        new ERC1967Proxy(
          address(new Staker(exa, weth, voter, factory, votingEscrow, rewardsController)),
          abi.encodeCall(Staker.initialize, ())
        )
      )
    );
    vm.label(address(staker), "Staker");

    bob = payable(vm.addr(BOB_KEY));
    vm.label(bob, "bob");
    deal(address(exa), bob, 500e18);
    deal(address(velo), bob, 500e18);
    deal(address(marketUSDC.asset()), address(this), 100_000e6);
    marketUSDC.asset().approve(address(marketUSDC), type(uint256).max);
    marketUSDC.deposit(100_000e6, bob);
    bob.transfer(500 ether);
  }

  function testStakeManyTimesAndUnstake() external {
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

    skip(1 days);
    uint256 earnedVELO = gauge.earned(staker);
    assertGt(earnedVELO, 0, "earned velo");
    staker.stakeETH{ value: amountETH }(bob, 0, 0);
    locked = votingEscrow.locked(staker.lockId());
    assertEq(locked.amount, int256(earnedVELO), "initial locked velo");
    assertEq(locked.isPermanent, true, "permanent lock");
    assertEq(voter.usedWeights(staker.lockId()), earnedVELO, "staker votes");
    assertEq(voter.weights(pool), earnedVELO + poolWeight, "pool weight");
    poolWeight += earnedVELO;

    skip(1 hours);
    uint256 epoch = block.timestamp - (block.timestamp % 1 weeks);
    uint256 newVELO = gauge.earned(staker);
    assertGt(newVELO, 0, "earned new velo");
    staker.stakeETH{ value: amountETH }(bob, 0, 0);
    assertEq(voter.usedWeights(staker.lockId()), earnedVELO += newVELO, "new votes");
    assertEq(voter.weights(pool), newVELO + poolWeight, "new weight");
    poolWeight += newVELO;

    skip(1 hours);
    newVELO = gauge.earned(staker);
    assertGt(newVELO, 0, "earned new velo");
    assertEq(block.timestamp - (block.timestamp % 1 weeks), epoch, "same epoch vote");
    staker.stakeETH{ value: amountETH }(bob, 0, 0);
    assertEq(voter.usedWeights(staker.lockId()), earnedVELO += newVELO, "more new votes");
    assertEq(voter.weights(pool), newVELO + poolWeight, "more new weight");
    poolWeight += newVELO;

    vm.prank(bob);
    staker.approve(address(this), type(uint256).max);
    staker.unstake(bob, 1e18);
    assertEq(staker.totalSupply(), 0, "no shares");
  }

  function testDonateVELO() external {
    uint256 balanceVELO = velo.balanceOf(bob);

    vm.startPrank(bob);
    velo.approve(address(staker), 100e18);
    staker.donateVELO(100e18);
    vm.stopPrank();

    assertEq(velo.balanceOf(bob), balanceVELO - 100e18, "velo balance");
  }

  function testPermitDonateVELO() external {
    uint256 balanceVELO = velo.balanceOf(bob);

    staker.donateVELO(permit(velo, 100e18));

    assertEq(velo.balanceOf(bob), balanceVELO - 100e18, "velo balance");
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
}
