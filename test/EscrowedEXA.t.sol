// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ForkTest, stdError } from "./Fork.t.sol";
import {
  EXA,
  Permit,
  EscrowedEXA,
  Untransferable,
  ISablierV2LockupLinear
} from "../contracts/periphery/EscrowedEXA.sol";

contract EscrowedEXATest is ForkTest {
  using FixedPointMathLib for uint256;

  EXA internal exa;
  EscrowedEXA internal esEXA;
  ISablierV2LockupLinear internal sablier;
  address internal constant REDEEMER = address(0x69);
  uint256 internal constant ALICE_KEY = 0x420;
  address internal alice;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 108_911_300);

    exa = EXA(deployment("EXA"));
    sablier = ISablierV2LockupLinear(deployment("SablierV2LockupLinear"));
    esEXA = EscrowedEXA(
      address(
        new ERC1967Proxy(
          address(new EscrowedEXA(exa, sablier)),
          abi.encodeCall(EscrowedEXA.initialize, (6 * 4 weeks, 1e17))
        )
      )
    );

    alice = vm.addr(ALICE_KEY);
    vm.label(alice, "alice");
    vm.prank(deployment("TimelockController"));
    exa.transfer(address(this), 100_000 ether);
    exa.approve(address(esEXA), 100_000 ether);
    esEXA.grantRole(esEXA.REDEEMER_ROLE(), REDEEMER);
  }

  function testMint() external {
    esEXA.mint(1_000 ether, address(this));
    assertEq(esEXA.balanceOf(address(this)), 1_000 ether);
  }

  function testMintToAnother() external {
    uint256 amount = 1_000 ether;
    esEXA.mint(amount, alice);
    assertEq(esEXA.balanceOf(alice), amount);
  }

  function testMintMoreThanBalance() external {
    vm.expectRevert(bytes(""));
    esEXA.mint(1_000_000 ether, address(this));
  }

  function testMintZero() external {
    vm.expectRevert(stdError.assertionError);
    esEXA.mint(0, address(this));
  }

  function testVest() external {
    uint256 amount = 1_000 ether;
    uint256 reserve = amount.mulWadDown(esEXA.reserveRatio());

    esEXA.mint(amount, address(this));
    uint256 exaBefore = exa.balanceOf(address(this));
    uint256 nextStreamId = ISablierV2Lockup(address(sablier)).nextStreamId();
    vm.expectEmit(true, true, true, true, address(esEXA));
    emit Vest(address(this), address(this), nextStreamId, amount);
    uint256 streamId = esEXA.vest(uint128(amount), address(this));

    assertEq(exaBefore, exa.balanceOf(address(this)) + reserve, "exa balance of sender -= reserve");
    assertEq(exa.balanceOf(address(esEXA)), reserve, "exa balance of esEXA == reserve");
    assertGt(streamId, 0);
    assertEq(streamId, nextStreamId);
  }

  function testVestToAnother() external {
    uint256 amount = 1_000 ether;
    uint256 reserve = amount.mulWadDown(esEXA.reserveRatio());

    esEXA.mint(amount, address(this));
    uint256 exaBefore = exa.balanceOf(address(this));
    uint256 nextStreamId = ISablierV2Lockup(address(sablier)).nextStreamId();
    vm.expectEmit(true, true, true, true, address(esEXA));
    emit Vest(address(this), alice, nextStreamId, amount);
    uint256 streamId = esEXA.vest(uint128(amount), alice);

    assertEq(exaBefore, exa.balanceOf(address(this)) + reserve, "exa balance of sender -= reserve");
    assertEq(exa.balanceOf(address(esEXA)), reserve, "exa balance of esEXA == reserve");
    assertGt(streamId, 0);
    assertEq(streamId, nextStreamId);

    vm.warp(block.timestamp + esEXA.vestingPeriod() / 2);

    uint256[] memory streams = new uint256[](1);
    streams[0] = streamId;
    vm.prank(alice);
    esEXA.withdrawMax(streams);

    assertEq(exa.balanceOf(alice), amount / 2, "exa balance of alice == amount / 2");
  }

  function testVestZero() external {
    vm.expectRevert(stdError.assertionError);
    esEXA.vest(0, address(this));
  }

  function testSetVestingPeriodAsAdmin() external {
    uint40 newPeriod = 4 weeks;
    vm.expectEmit(true, true, true, true, address(esEXA));
    emit VestingPeriodSet(newPeriod);
    esEXA.setVestingPeriod(newPeriod);
    assertEq(esEXA.vestingPeriod(), newPeriod);
  }

  function testSetVestingPeriodAsNotAdmin() external {
    vm.startPrank(alice);
    vm.expectRevert(bytes(""));
    esEXA.setVestingPeriod(4 weeks);
  }

  function testGrantTransferrerRoleAsAdmin() external {
    esEXA.grantRole(esEXA.TRANSFERRER_ROLE(), alice);
    assertTrue(esEXA.hasRole(esEXA.TRANSFERRER_ROLE(), alice));
  }

  function testTransferToTransferrer() external {
    esEXA.mint(1 ether, address(this));

    esEXA.grantRole(esEXA.TRANSFERRER_ROLE(), alice);
    esEXA.transfer(alice, 1 ether);
    assertEq(esEXA.balanceOf(alice), 1 ether);
  }

  function testTransferToNotTransferrer() external {
    esEXA.mint(1 ether, address(this));
    vm.expectRevert(Untransferable.selector);
    esEXA.transfer(alice, 1 ether);
  }

  function testSetReserveRatioAsAdmin() external {
    uint256 newRatio = 5e16;
    vm.expectEmit(true, true, true, true, address(esEXA));
    emit ReserveRatioSet(newRatio);
    esEXA.setReserveRatio(newRatio);
    assertEq(esEXA.reserveRatio(), newRatio);
  }

  function testSetReserveRatioAsNotAdmin() external {
    vm.startPrank(alice);
    vm.expectRevert(bytes(""));
    esEXA.setReserveRatio(5e16);
  }

  function testCancelShouldGiveReservesBack() external {
    uint256 initialAmount = 1_000 ether;
    uint256 reserve = initialAmount.mulWadDown(esEXA.reserveRatio());
    esEXA.mint(initialAmount * 2, address(this));

    uint256 initialEXA = exa.balanceOf(address(this));

    uint256 streamId1 = esEXA.vest(uint128(initialAmount), address(this));
    assertEq(exa.balanceOf(address(this)), initialEXA - reserve);

    uint256 streamId2 = esEXA.vest(uint128(initialAmount), address(this));
    assertEq(exa.balanceOf(address(this)), initialEXA - reserve * 2);

    vm.warp(block.timestamp + esEXA.vestingPeriod() / 2);

    uint256 withdrawableAmount = ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streamId1);
    withdrawableAmount += ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streamId2);
    uint256 esEXABefore = esEXA.balanceOf(address(this));
    uint256[] memory streamIds = new uint256[](2);
    streamIds[0] = streamId1;
    streamIds[1] = streamId2;
    esEXA.cancel(streamIds);

    assertEq(exa.balanceOf(address(this)), initialEXA + withdrawableAmount, "should give reserves back");
    assertEq(esEXA.reserves(streamId1), 0, "reserves[streamId1] == 0");
    assertEq(esEXA.reserves(streamId2), 0, "reserves[streamId2] == 0");
    assertEq(esEXA.balanceOf(address(this)), esEXABefore + initialAmount, "should give back half of the esexa");
  }

  function testVestToAnotherAndCancel() external {
    uint256 amount = 1_000 ether;
    uint256 reserve = amount.mulWadDown(esEXA.reserveRatio());

    esEXA.mint(amount, address(this));
    uint256[] memory streams = new uint256[](1);
    streams[0] = esEXA.vest(uint128(amount), alice);

    vm.warp(block.timestamp + esEXA.vestingPeriod() / 2);
    vm.prank(alice);
    esEXA.cancel(streams);

    assertEq(exa.balanceOf(alice), amount / 2 + reserve, "exa.balanceOf(alice) == amount / 2 + reserve");
    assertEq(esEXA.balanceOf(alice), amount / 2, "esEXA.balanceOf(alice) == amount / 2");
  }

  function testCancelShouldDeleteReserves() external {
    uint256 amount = 1_000 ether;
    uint256 reserve = amount.mulWadDown(esEXA.reserveRatio());
    esEXA.mint(amount, address(this));

    uint256 streamId = esEXA.vest(uint128(amount), address(this));
    vm.warp(block.timestamp + esEXA.vestingPeriod() / 2);

    uint256 exaBefore = exa.balanceOf(address(this));
    uint256 esEXABefore = esEXA.balanceOf(address(this));
    uint256 withdrawableAmount = ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streamId);
    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId;
    esEXA.cancel(streamIds);

    assertEq(esEXA.reserves(streamId), 0, "reserves[streamId] == 0");
    assertEq(esEXA.balanceOf(address(this)), esEXABefore + amount / 2, "should give back half of the esexa");
    assertEq(exa.balanceOf(address(this)), exaBefore + reserve + withdrawableAmount, "should give back reserve");
  }

  function testCancelTwiceShouldRevert() external {
    uint256 amount = 1_000 ether;
    esEXA.mint(amount, address(this));

    uint256 streamId = esEXA.vest(uint128(amount), address(this));
    vm.warp(block.timestamp + esEXA.vestingPeriod() / 2);

    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId;
    esEXA.cancel(streamIds);
    vm.expectRevert(abi.encodeWithSelector(SablierV2Lockup_StreamDepleted.selector, streamId));
    esEXA.cancel(streamIds);
  }

  function testCancelWithInvalidAccount() external {
    uint256 initialAmount = 1_000 ether;
    uint256 reserve = initialAmount.mulWadDown(esEXA.reserveRatio());
    esEXA.mint(initialAmount, address(this));

    uint256 initialEXA = exa.balanceOf(address(this));

    uint256 streamId1 = esEXA.vest(uint128(initialAmount), address(this));
    assertEq(exa.balanceOf(address(this)), initialEXA - reserve);

    vm.warp(block.timestamp + esEXA.vestingPeriod() / 2);

    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId1;
    vm.prank(alice);
    vm.expectRevert(stdError.assertionError);
    esEXA.cancel(streamIds);
  }

  function testWithdrawMaxFromMultipleStreams() external {
    uint256 initialAmount = 1_000 ether;
    esEXA.mint(initialAmount, address(this));
    uint256[] memory streams = new uint256[](4);
    streams[0] = esEXA.vest(uint128(200 ether), address(this));

    vm.warp(block.timestamp + 2 days);
    streams[1] = esEXA.vest(uint128(300 ether), address(this));

    vm.warp(block.timestamp + 7 days);
    streams[2] = esEXA.vest(uint128(100 ether), address(this));

    vm.warp(block.timestamp + 3 weeks);
    streams[3] = esEXA.vest(uint128(400 ether), address(this));

    vm.warp(block.timestamp + 5 weeks);
    uint256 balanceEXA = exa.balanceOf(address(this));
    uint256 withdrawableAmount;
    for (uint256 i = 0; i < streams.length; ++i) {
      withdrawableAmount += ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streams[i]);
    }
    esEXA.withdrawMax(streams);
    assertEq(exa.balanceOf(address(this)), balanceEXA + withdrawableAmount);
    for (uint256 i = 0; i < streams.length; ++i) {
      assertEq(ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streams[i]), 0);
    }
  }

  function testWithdrawMaxWithInvalidSender() external {
    uint256 initialAmount = 1_000 ether;
    esEXA.mint(initialAmount, address(this));
    uint256[] memory streams = new uint256[](1);
    streams[0] = esEXA.vest(uint128(1_000 ether), address(this));

    vm.warp(block.timestamp + 5 weeks);
    vm.prank(alice);
    vm.expectRevert(stdError.assertionError);
    esEXA.withdrawMax(streams);
  }

  function testRedeemAsRedeemer() external {
    uint256 amount = 1_000 ether;
    esEXA.mint(amount, REDEEMER);

    vm.prank(REDEEMER);
    esEXA.redeem(amount, REDEEMER);
    assertEq(exa.balanceOf(REDEEMER), amount, "exa.balanceOf(redeemer) == amount");
  }

  function testRedeemAsRedeemerToAnother() external {
    uint256 amount = 1_000 ether;
    esEXA.mint(amount, REDEEMER);

    vm.prank(REDEEMER);
    esEXA.redeem(amount, alice);
    assertEq(exa.balanceOf(REDEEMER), 0, "exa.balanceOf(redeemer) == exaBefore");
    assertEq(exa.balanceOf(alice), amount, "exa.balanceOf(alice) == amount");
  }

  function testRedeemAsNotRedeemer() external {
    uint256 amount = 1_000 ether;
    exa.transfer(alice, amount);

    vm.startPrank(alice);
    exa.approve(address(esEXA), amount);
    esEXA.mint(amount, alice);
    vm.expectRevert(bytes(""));
    esEXA.redeem(amount, alice);
    vm.stopPrank();
  }

  function testVestWithPermitReserve() external {
    uint256 amount = 1_000 ether;
    esEXA.mint(amount, alice);
    uint256 reserve = amount.mulWadDown(esEXA.reserveRatio());
    exa.transfer(alice, reserve);

    uint256 exaBefore = exa.balanceOf(alice);
    uint256 nextStreamId = ISablierV2Lockup(address(sablier)).nextStreamId();

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      ALICE_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          exa.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              alice,
              esEXA,
              reserve,
              exa.nonces(alice),
              block.timestamp
            )
          )
        )
      )
    );

    vm.expectEmit(true, true, true, true, address(esEXA));
    emit Vest(alice, alice, nextStreamId, amount);
    vm.prank(alice);
    uint256 streamId = esEXA.vest(uint128(amount), alice, Permit(reserve, block.timestamp, v, r, s));

    assertEq(exaBefore, exa.balanceOf(alice) + reserve, "exa balance of alice -= reserve");
    assertEq(exa.balanceOf(address(esEXA)), reserve, "exa balance of esEXA == reserve");
    assertGt(streamId, 0);
    assertEq(streamId, nextStreamId);

    vm.warp(block.timestamp + esEXA.vestingPeriod() / 2);

    uint256[] memory streams = new uint256[](1);
    streams[0] = streamId;
    vm.prank(alice);
    esEXA.withdrawMax(streams);
    assertEq(exa.balanceOf(alice), amount / 2, "exa balance of alice == amount / 2");
  }

  event ReserveRatioSet(uint256 reserveRatio);
  event VestingPeriodSet(uint256 vestingPeriod);
  event Vest(address indexed caller, address indexed account, uint256 indexed streamId, uint256 amount);
}

error SablierV2Lockup_StreamDepleted(uint256);

interface ISablierV2Lockup {
  function nextStreamId() external view returns (uint256);

  function withdraw(uint256 streamId, address to, uint128 amount) external;

  function withdrawMax(uint256 streamId, address to) external;

  function wasCanceled(uint256 streamId) external view returns (bool result);

  function withdrawableAmountOf(uint256 streamId) external view returns (uint128 withdrawableAmount);
}
