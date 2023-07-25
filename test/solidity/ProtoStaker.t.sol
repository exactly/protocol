// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ForkTest } from "./Fork.t.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITransparentUpgradeableProxy, ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { RewardsController, ClaimPermit, Market } from "../../contracts/RewardsController.sol";
import { ProtoStaker, EXA, WETH, ERC20, IPool, IGauge, Permit } from "../../contracts/periphery/ProtoStaker.sol";

contract ProtoStakerTest is ForkTest {
  uint256 internal constant BOB_KEY = 0xb0b;
  address internal bob;

  WETH internal weth;
  ERC20 internal exa;
  IPool internal pool;
  IGauge internal gauge;
  Market internal marketUSDC;
  ProtoStaker internal protoStaker;
  RewardsController internal rewardsController;

  function setUp() external _checkBalances {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 107_353_677);

    exa = ERC20(deployment("EXA"));
    weth = WETH(payable(deployment("WETH")));
    pool = IPool(deployment("EXAPool"));
    gauge = IGauge(deployment("EXAGauge"));
    marketUSDC = Market(deployment("MarketUSDC"));
    rewardsController = RewardsController(deployment("RewardsController"));
    protoStaker = ProtoStaker(
      address(
        new ERC1967Proxy(
          address(
            new ProtoStaker(EXA(address(exa)), weth, IPool(address(pool)), IGauge(address(gauge)), rewardsController)
          ),
          abi.encodeCall(ProtoStaker.initialize, ())
        )
      )
    );
    vm.label(address(protoStaker), "ProtoStaker");
    vm.startPrank(deployment("ProxyAdmin"));
    ITransparentUpgradeableProxy(payable(address(rewardsController))).upgradeTo(address(new RewardsController()));
    vm.stopPrank();

    bob = vm.addr(BOB_KEY);
    vm.label(bob, "bob");
    deal(address(exa), bob, 500 ether);
    deal(address(marketUSDC.asset()), address(this), 100_000e6);
    marketUSDC.asset().approve(address(marketUSDC), type(uint256).max);
    marketUSDC.deposit(100_000e6, bob);
    payable(bob).transfer(500 ether);
  }

  function testStakeWithExactETH() external _checkBalances {
    uint256 amountEXA = 100 ether;
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          exa.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              protoStaker,
              amountEXA,
              exa.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeBalance{ value: amountETH }(Permit(payable(bob), amountEXA, block.timestamp, v, r, s));

    assertGt(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA - amountEXA, "exa balance");
    assertEq(bob.balance, balanceETH - amountETH, "eth balance");
  }

  function testStakeWithLessETH() external _checkBalances {
    uint256 amountEXA = 100 ether;
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          exa.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              protoStaker,
              amountEXA,
              exa.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    vm.prank(bob);
    payable(this).transfer(amountETH - 0.05 ether);
    protoStaker.stakeBalance{ value: amountETH - 0.05 ether }(
      Permit(payable(bob), amountEXA, block.timestamp, v, r, s)
    );

    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA, "exa balance");
    assertEq(bob.balance, balanceETH, "eth balance");
  }

  function testStakeWithMoreETH() external _checkBalances {
    uint256 amountEXA = 100 ether;
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          exa.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              protoStaker,
              amountEXA,
              exa.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    vm.prank(bob);
    payable(this).transfer(amountETH + 1 ether);
    protoStaker.stakeBalance{ value: amountETH + 1 ether }(Permit(payable(bob), amountEXA, block.timestamp, v, r, s));

    assertGt(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(exa.balanceOf(bob), balanceEXA - amountEXA, "exa balance");
    assertEq(bob.balance, balanceETH - amountETH, "eth balance");
  }

  function testAddRewardWithExactETH() external _checkBalances {
    skip(4 weeks);
    uint256 amountEXA = rewardsController.allClaimable(bob, exa);
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;

    bool[] memory ops = new bool[](2);
    ops[0] = false;
    ops[1] = true;
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
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

    vm.prank(bob);
    payable(this).transfer(amountETH);
    protoStaker.stakeRewards{ value: amountETH }(ClaimPermit(bob, assets, block.timestamp, v, r, s));

    assertGt(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(rewardsController.allClaimable(bob, exa), 0, "claimable");
    assertEq(bob.balance, balanceETH - amountETH, "eth balance");
  }

  function testAddRewardWithLessETH() external _checkBalances {
    skip(4 weeks);
    uint256 amountEXA = rewardsController.allClaimable(bob, exa);
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;
    uint256 balanceEXA = exa.balanceOf(bob);

    bool[] memory ops = new bool[](2);
    ops[0] = false;
    ops[1] = true;
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
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

    vm.prank(bob);
    payable(this).transfer(amountETH - 0.1 ether);
    protoStaker.stakeRewards{ value: amountETH - 0.1 ether }(ClaimPermit(bob, assets, block.timestamp, v, r, s));

    assertEq(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(rewardsController.allClaimable(bob, exa), 0, "claimable");
    assertEq(bob.balance, balanceETH, "eth balance");
    assertEq(exa.balanceOf(bob), balanceEXA + amountEXA, "exa balance");
  }

  function testAddRewardWithMoreETH() external _checkBalances {
    skip(4 weeks);
    uint256 amountEXA = rewardsController.allClaimable(bob, exa);
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    uint256 balanceETH = bob.balance;

    bool[] memory ops = new bool[](2);
    ops[0] = false;
    ops[1] = true;
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
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

    vm.prank(bob);
    payable(this).transfer(amountETH + 2 ether);
    protoStaker.stakeRewards{ value: amountETH + 2 ether }(ClaimPermit(bob, assets, block.timestamp, v, r, s));

    assertGt(gauge.balanceOf(bob), 0, "gauge balance");
    assertEq(rewardsController.allClaimable(bob, exa), 0, "claimable");
    assertEq(bob.balance, balanceETH - amountETH, "eth balance");
  }

  modifier _checkBalances() {
    _;
    assertEq(pool.balanceOf(address(protoStaker)), 0);
    assertEq(gauge.balanceOf(address(protoStaker)), 0);
    assertEq(weth.balanceOf(address(protoStaker)), 0);
    assertEq(exa.balanceOf(address(protoStaker)), 0);
  }

  // solhint-disable-next-line no-empty-blocks
  receive() external payable {}
}
