// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ForkTest } from "./Fork.t.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITransparentUpgradeableProxy, ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { RewardsController, ClaimPermit, Market } from "../contracts/RewardsController.sol";
import {
  WETH,
  ERC20,
  Permit,
  IPool,
  IGauge,
  IPermit2,
  IPoolFactory,
  ProtoStaker
} from "../contracts/periphery/ProtoStaker.sol";

contract ProtoStakerTest is ForkTest {
  using FixedPointMathLib for uint256;

  uint256 internal constant BOB_KEY = 0xb0b;
  address payable internal bob;

  WETH internal weth;
  ERC20 internal exa;
  IPool internal pool;
  IGauge internal gauge;
  Market internal marketUSDC;
  IPermit2 internal permit2;
  ProtoStaker internal protoStaker;
  IPoolFactory internal factory;
  RewardsController internal rewardsController;

  function setUp() external _checkBalances {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 107_399_795);

    exa = ERC20(deployment("EXA"));
    weth = WETH(payable(deployment("WETH")));
    pool = IPool(deployment("EXAPool"));
    gauge = IGauge(deployment("EXAGauge"));
    permit2 = IPermit2(deployment("Permit2"));
    factory = IPoolFactory(deployment("VelodromePoolFactory"));
    marketUSDC = Market(deployment("MarketUSDC"));
    rewardsController = RewardsController(deployment("RewardsController"));
    protoStaker = ProtoStaker(
      payable(
        new ERC1967Proxy(
          address(new ProtoStaker(exa, weth, gauge, factory, deployment("SocketGateway"), permit2, rewardsController)),
          abi.encodeCall(ProtoStaker.initialize, ())
        )
      )
    );
    vm.label(address(protoStaker), "ProtoStaker");
    vm.startPrank(deployment("ProxyAdmin"));
    ITransparentUpgradeableProxy(payable(address(rewardsController))).upgradeTo(address(new RewardsController()));
    vm.stopPrank();

    bob = payable(vm.addr(BOB_KEY));
    vm.label(bob, "bob");
    deal(address(exa), bob, 500e18);
    deal(address(marketUSDC.asset()), address(this), 100_000e6);
    marketUSDC.asset().approve(address(marketUSDC), type(uint256).max);
    marketUSDC.deposit(100_000e6, bob);
    bob.transfer(500 ether);
  }

  function testProtoStakeETH() external _checkBalances {
    uint256 amountETH = 1 ether;
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeETH{ value: amountETH }(bob, 0, 0);

    assertGt(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA, "exa balance");
    assertEq(bob.balance, balanceETH - amountETH, "eth balance");
  }

  function testProtoStakeETHWithKeepETH() external _checkBalances {
    uint256 amountETH = 1 ether;
    uint256 keepETH = 0.1 ether;
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeETH{ value: amountETH }(bob, 0, keepETH);

    assertGt(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA, "exa balance");
    assertEq(bob.balance, balanceETH + keepETH - amountETH, "eth balance");
  }

  function testProtoStakeETHWithKeepETHHigherThanValue() external _checkBalances {
    uint256 amountETH = 1 ether;
    uint256 keepETH = 1 ether + 1;
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeETH{ value: amountETH }(bob, 0, keepETH);

    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA, "exa balance");
    assertEq(bob.balance, balanceETH, "eth balance");
  }

  function testProtoStakeETHWithKeepETHEqualToValue() external _checkBalances {
    uint256 amountETH = 1 ether;
    uint256 keepETH = 1 ether;
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeETH{ value: amountETH }(bob, 0, keepETH);

    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA, "exa balance");
    assertEq(bob.balance, balanceETH, "eth balance");
  }

  function testProtoStakeETHWithMinEXA() external _checkBalances {
    uint256 amountETH = 1 ether;
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeETH{ value: amountETH }(bob, type(uint256).max, 0);

    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA, "exa balance");
    assertEq(bob.balance, balanceETH, "eth balance");
  }

  function testProtoStakeETHWithMinEXAAndKeepETH() external _checkBalances {
    uint256 amountETH = 1 ether;
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeETH{ value: amountETH }(bob, type(uint256).max, 0.1 ether);

    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA, "exa balance");
    assertEq(bob.balance, balanceETH, "eth balance");
  }

  function testProtoStakeBalanceWithExactETH() external _checkBalances {
    uint256 amountEXA = 100e18;
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeBalance{ value: amountETH }(permit(amountEXA), 0, 0);

    assertGt(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA - amountEXA, "exa balance");
    assertEq(bob.balance, balanceETH - amountETH, "eth balance");
  }

  function testProtoStakeBalanceWithLessETH() external _checkBalances {
    uint256 amountEXA = 100e18;
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);

    vm.prank(bob);
    payable(this).transfer(amountETH - 0.05 ether);
    protoStaker.stakeBalance{ value: amountETH - 0.05 ether }(permit(amountEXA), 0, 0);

    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA, "exa balance");
    assertEq(bob.balance, balanceETH, "eth balance");
  }

  function testProtoStakeBalanceWithMoreETH() external _checkBalances {
    uint256 amountEXA = 100e18;
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);

    vm.prank(bob);
    payable(this).transfer(amountETH + 1 ether);
    protoStaker.stakeBalance{ value: amountETH + 1 ether }(permit(amountEXA), 0, 0);

    assertGt(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA - amountEXA, "exa balance");
    assertEq(bob.balance, balanceETH - amountETH - 1 ether, "eth balance");
  }

  function testProtoStakeRewardWithExactETH() external _checkBalances {
    skip(4 weeks);
    uint256 amountEXA = rewardsController.allClaimable(bob, exa);
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeRewards{ value: amountETH }(claimPermit(assets), 0, 0);

    assertGt(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(rewardsController.allClaimable(bob, exa), 0, "claimable");
    assertEq(bob.balance, balanceETH - amountETH, "eth balance");
  }

  function testProtoStakeRewardWithLessETH() external _checkBalances {
    skip(4 weeks);
    uint256 amountEXA = rewardsController.allClaimable(bob, exa);
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    vm.prank(bob);
    payable(this).transfer(amountETH - 1e8);
    protoStaker.stakeRewards{ value: amountETH - 1e8 }(claimPermit(assets), 0, 0);

    assertEq(bob.balance, balanceETH, "eth balance");
    assertEq(exa.balanceOf(bob), amountEXA + balanceEXA, "exa balance");
    assertEq(rewardsController.allClaimable(bob, exa), 0, "claimable");
    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
  }

  function testProtoStakeRewardWithMoreETH() external _checkBalances {
    skip(4 weeks);
    uint256 amountEXA = rewardsController.allClaimable(bob, exa);
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    vm.prank(bob);
    payable(this).transfer(amountETH + 2 ether);
    protoStaker.stakeRewards{ value: amountETH + 2 ether }(claimPermit(assets), 0, 0);

    assertEq(bob.balance, balanceETH - amountETH - 2 ether, "eth balance");
    assertEq(exa.balanceOf(bob), balanceEXA, "exa balance");
    assertEq(rewardsController.allClaimable(bob, exa), 0, "claimable");
    assertGt(gauge.balanceOf(bob), 0, "gauge balance");
  }

  function testProtoStakeWrongReward() external _checkBalances {
    ERC20 op = ERC20(deployment("OP"));
    skip(4 weeks);
    uint256 amountOP = rewardsController.allClaimable(bob, op);
    uint256 amountETH = 0.5 ether;
    uint256 balanceETH = bob.balance;
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = op;

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeRewards{ value: amountETH }(claimPermit(assets), 0, 0);

    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(bob.balance, balanceETH, "eth balance");
    assertEq(rewardsController.allClaimable(bob, op), amountOP, "claimable");
  }

  function testProtoStakeRewardWhenZeroRewards() external _checkBalances {
    uint256 amountEXA = rewardsController.allClaimable(bob, exa);
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeRewards{ value: amountETH }(claimPermit(assets), 0, 0);

    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(rewardsController.allClaimable(bob, exa), 0, "claimable");
    assertEq(bob.balance, balanceETH - amountETH, "eth balance");
  }

  function testProtoStakeRewardsWithNoETH() external _checkBalances {
    skip(4 weeks);
    uint256 amountEXA = rewardsController.allClaimable(bob, exa);
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    protoStaker.stakeRewards{ value: 0 }(claimPermit(assets), 0, 0);

    assertEq(bob.balance, balanceETH, "eth balance");
    assertEq(exa.balanceOf(bob), balanceEXA + amountEXA, "exa balance");
    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
  }

  function testProtoStakeRewardsWithoutPermitAssets() external _checkBalances {
    skip(4 weeks);
    uint256 amountETH = 0.5 ether;
    uint256 amountEXA = rewardsController.allClaimable(bob, exa);
    uint256 balanceETH = bob.balance;
    ERC20[] memory assets = new ERC20[](0);

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeRewards{ value: amountETH }(claimPermit(assets), 0, 0);

    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(bob.balance, balanceETH, "eth balance");
    assertEq(rewardsController.allClaimable(bob, exa), amountEXA, "claimable");
  }

  modifier _checkBalances() {
    _;
    assertEq(address(protoStaker).balance, 0);
    assertEq(pool.balanceOf(address(protoStaker)), 0);
    assertEq(gauge.balanceOf(address(protoStaker)), 0);
    assertEq(weth.balanceOf(address(protoStaker)), 0);
    assertEq(exa.balanceOf(address(protoStaker)), 0);
  }

  function permit(uint256 value) internal view returns (Permit memory p) {
    p = Permit(bob, value, block.timestamp, 0, bytes32(0), bytes32(0));
    (p.v, p.r, p.s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          exa.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              p.owner,
              protoStaker,
              p.value,
              exa.nonces(bob),
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
              protoStaker,
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
