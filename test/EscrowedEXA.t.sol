// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ForkTest, stdError } from "./Fork.t.sol";
import { EXA, EscrowedEXA, Untransferable, ISablierV2LockupLinear } from "../contracts/periphery/EscrowedEXA.sol";

contract EscrowedEXATest is ForkTest {
  using FixedPointMathLib for uint256;

  EXA internal exa;
  EscrowedEXA internal esEXA;
  ISablierV2LockupLinear internal sablier;
  address internal constant ALICE = address(0x420);
  address internal constant REDEEMER = address(0x69);

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

    vm.prank(deployment("TimelockController"));
    exa.transfer(address(this), 100_000 ether);
    esEXA.grantRole(esEXA.REDEEMER_ROLE(), REDEEMER);
  }

  function testMint() external {
    exa.approve(address(esEXA), 1_000 ether);
    esEXA.mint(1_000 ether);
    assertEq(esEXA.balanceOf(address(this)), 1_000 ether);
  }

  function testMintMoreThanBalance() external {
    exa.approve(address(esEXA), 1_000_000 ether);
    vm.expectRevert(bytes(""));
    esEXA.mint(1_000_000 ether);
  }

  function testMintZero() external {
    vm.expectRevert(stdError.assertionError);
    esEXA.mint(0);
  }

  function testVest() external {
    uint256 amount = 1_000 ether;
    uint256 reserve = amount.mulWadDown(esEXA.reserveFee());

    exa.approve(address(esEXA), amount + reserve);
    esEXA.mint(amount);
    uint256 exaBefore = exa.balanceOf(address(this));
    uint256 nextStreamId = ISablierV2Lockup(address(sablier)).nextStreamId();
    vm.expectEmit(true, true, true, true, address(esEXA));
    emit Vest(address(this), nextStreamId, amount);
    uint256 streamId = esEXA.vest(uint128(amount));

    assertEq(exaBefore, exa.balanceOf(address(this)) + reserve, "exa balance of sender -= reserve");
    assertEq(exa.balanceOf(address(esEXA)), reserve, "exa balance of esEXA == reserve");
    assertGt(streamId, 0);
    assertEq(streamId, nextStreamId);
  }

  function testVestAndCancel() external {
    uint256 amount = 1_000 ether;
    uint256 reserve = amount.mulWadDown(esEXA.reserveFee());
    exa.approve(address(esEXA), amount + reserve);
    esEXA.mint(amount);

    uint256 streamId = esEXA.vest(uint128(amount));
    vm.warp(block.timestamp + esEXA.vestingPeriod() / 2);
    assertEq(ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streamId), amount / 2);
    assertFalse(ISablierV2Lockup(address(sablier)).wasCanceled(streamId), "stream is not canceled");
    assertEq(exa.balanceOf(address(esEXA)), reserve, "exa.balanceOf(esEXA) == reserve + amount");

    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId;

    uint256 remainingesEXA = amount / 2; // half period passed
    reserve = (amount + remainingesEXA).mulWadDown(esEXA.reserveFee());
    exa.approve(address(esEXA), amount + reserve);
    esEXA.mint(amount);

    uint256 newStreamId = esEXA.vest(uint128(amount), streamIds);

    assertEq(exa.balanceOf(address(esEXA)), reserve, "exa.balanceOf(esEXA) == reserve + amount");
    assertEq(newStreamId, streamId + 1);
    assertTrue(ISablierV2Lockup(address(sablier)).wasCanceled(streamId));
    assertEq(ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streamId), 0);

    vm.warp(block.timestamp + 5 days);
    assertEq(ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streamId), 0);
    assertGt(ISablierV2Lockup(address(sablier)).withdrawableAmountOf(newStreamId), 0);
  }

  function testVestAndCancelWithInvalidAccount() external {
    exa.approve(address(esEXA), 2_100 ether);
    esEXA.mint(2_000 ether);
    uint256 streamId = esEXA.vest(1_000 ether);

    vm.warp(block.timestamp + 1 days);
    assertGt(ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streamId), 0);
    assertFalse(ISablierV2Lockup(address(sablier)).wasCanceled(streamId));

    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId;
    vm.prank(ALICE);
    vm.expectRevert(stdError.assertionError);
    esEXA.vest(1_000 ether, streamIds);
  }

  function testVestZero() external {
    vm.expectRevert(SablierV2Lockup_DepositAmountZero.selector);
    esEXA.vest(0);
  }

  function testSetVestingPeriodAsAdmin() external {
    uint40 newPeriod = 4 weeks;
    vm.expectEmit(true, true, true, true, address(esEXA));
    emit VestingPeriodSet(newPeriod);
    esEXA.setVestingPeriod(newPeriod);
    assertEq(esEXA.vestingPeriod(), newPeriod);
  }

  function testSetVestingPeriodAsNotAdmin() external {
    vm.startPrank(ALICE);
    vm.expectRevert(bytes(""));
    esEXA.setVestingPeriod(4 weeks);
  }

  function testGrantTransferrerRoleAsAdmin() external {
    esEXA.grantRole(esEXA.TRANSFERRER_ROLE(), ALICE);
    assertTrue(esEXA.hasRole(esEXA.TRANSFERRER_ROLE(), ALICE));
  }

  function testTransferToTransferrer() external {
    exa.approve(address(esEXA), 1 ether);
    esEXA.mint(1 ether);

    esEXA.grantRole(esEXA.TRANSFERRER_ROLE(), ALICE);
    esEXA.transfer(ALICE, 1 ether);
    assertEq(esEXA.balanceOf(ALICE), 1 ether);
  }

  function testTransferToNotTransferrer() external {
    exa.approve(address(esEXA), 1 ether);
    esEXA.mint(1 ether);
    vm.expectRevert(Untransferable.selector);
    esEXA.transfer(ALICE, 1 ether);
  }

  function testSetReserveFeeAsAdmin() external {
    uint256 newFee = 5e16;
    vm.expectEmit(true, true, true, true, address(esEXA));
    emit ReserveFeeSet(newFee);
    esEXA.setReserveFee(newFee);
    assertEq(esEXA.reserveFee(), newFee);
  }

  function testSetReserveFeeAsNotAdmin() external {
    vm.startPrank(ALICE);
    vm.expectRevert(bytes(""));
    esEXA.setReserveFee(5e16);
  }

  function testCancelShouldGiveReservesBack() external {
    uint256 initialAmount = 1_000 ether;
    uint256 reserve = initialAmount.mulWadDown(esEXA.reserveFee());
    exa.approve(address(esEXA), initialAmount * 2);
    esEXA.mint(initialAmount * 2);

    uint256 initialEXA = exa.balanceOf(address(this));

    exa.approve(address(esEXA), reserve);
    uint256 streamId1 = esEXA.vest(uint128(initialAmount));
    assertEq(exa.balanceOf(address(this)), initialEXA - reserve);

    exa.approve(address(esEXA), reserve);
    uint256 streamId2 = esEXA.vest(uint128(initialAmount));
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

  function testCancelShouldDeleteReserves() external {
    uint256 amount = 1_000 ether;
    uint256 reserve = amount.mulWadDown(esEXA.reserveFee());
    exa.approve(address(esEXA), amount + reserve);
    esEXA.mint(amount);

    uint256 streamId = esEXA.vest(uint128(amount));
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
    uint256 reserve = amount.mulWadDown(esEXA.reserveFee());
    exa.approve(address(esEXA), amount + reserve);
    esEXA.mint(amount);

    uint256 streamId = esEXA.vest(uint128(amount));
    vm.warp(block.timestamp + esEXA.vestingPeriod() / 2);

    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId;
    esEXA.cancel(streamIds);
    vm.expectRevert(abi.encodeWithSelector(SablierV2Lockup_StreamDepleted.selector, streamId));
    esEXA.cancel(streamIds);
  }

  function testCancelWithInvalidAccount() external {
    uint256 initialAmount = 1_000 ether;
    uint256 reserve = initialAmount.mulWadDown(esEXA.reserveFee());
    exa.approve(address(esEXA), initialAmount);
    esEXA.mint(initialAmount);

    uint256 initialEXA = exa.balanceOf(address(this));

    exa.approve(address(esEXA), reserve);
    uint256 streamId1 = esEXA.vest(uint128(initialAmount));
    assertEq(exa.balanceOf(address(this)), initialEXA - reserve);

    vm.warp(block.timestamp + esEXA.vestingPeriod() / 2);

    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId1;
    vm.prank(ALICE);
    vm.expectRevert(stdError.assertionError);
    esEXA.cancel(streamIds);
  }

  function testVestAndCancelHigherStream() external {
    uint256 initialAmount = 1_000 ether;
    uint256 reserve = initialAmount.mulWadDown(esEXA.reserveFee());
    exa.approve(address(esEXA), initialAmount + reserve);
    esEXA.mint(initialAmount);
    uint256 streamId = esEXA.vest(uint128(initialAmount));

    vm.warp(block.timestamp + esEXA.vestingPeriod() / 2);

    uint256 withdrawableAmount = ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streamId);
    uint256 newAmount = 100 ether;
    uint256 newReserve = newAmount.mulWadDown(esEXA.reserveFee());
    exa.approve(address(esEXA), newAmount + newReserve);
    esEXA.mint(newAmount);

    uint256 exaBefore = exa.balanceOf(address(this));
    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId;
    esEXA.vest(uint128(newAmount), streamIds);

    assertEq(exa.balanceOf(address(this)), exaBefore + reserve / 2 - newReserve + withdrawableAmount);
    assertGt(exa.balanceOf(address(this)), exaBefore);
  }

  function testWithdrawMaxFromMultipleStreams() external {
    uint256 initialAmount = 1_000 ether;
    uint256 reserve = initialAmount.mulWadDown(esEXA.reserveFee());
    exa.approve(address(esEXA), initialAmount + reserve);
    esEXA.mint(initialAmount);
    uint256[] memory streams = new uint256[](4);
    streams[0] = esEXA.vest(uint128(200 ether));

    vm.warp(block.timestamp + 2 days);
    streams[1] = esEXA.vest(uint128(300 ether));

    vm.warp(block.timestamp + 7 days);
    streams[2] = esEXA.vest(uint128(100 ether));

    vm.warp(block.timestamp + 3 weeks);
    streams[3] = esEXA.vest(uint128(400 ether));

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
    uint256 reserve = initialAmount.mulWadDown(esEXA.reserveFee());
    exa.approve(address(esEXA), initialAmount + reserve);
    esEXA.mint(initialAmount);
    uint256[] memory streams = new uint256[](1);
    streams[0] = esEXA.vest(uint128(1_000 ether));

    vm.warp(block.timestamp + 5 weeks);
    vm.prank(ALICE);
    vm.expectRevert(stdError.assertionError);
    esEXA.withdrawMax(streams);
  }

  function testUnmintAsRedeemer() external {
    exa.transfer(REDEEMER, 1_000 ether);

    vm.startPrank(REDEEMER);
    uint256 amount = 1_000 ether;
    uint256 exaBefore = exa.balanceOf(REDEEMER);
    exa.approve(address(esEXA), amount);
    esEXA.mint(amount);
    assertEq(exa.balanceOf(REDEEMER), exaBefore - amount);
    esEXA.redeem(amount);
    assertEq(exa.balanceOf(REDEEMER), exaBefore);
  }

  function testUnmintAsNotRedeemer() external {
    exa.transfer(ALICE, 1_000 ether);

    vm.startPrank(ALICE);
    uint256 amount = 1_000 ether;
    exa.approve(address(esEXA), amount);
    esEXA.mint(amount);
    vm.expectRevert(bytes(""));
    esEXA.redeem(amount);
  }

  event ReserveFeeSet(uint256 reserveFee);
  event VestingPeriodSet(uint256 vestingPeriod);
  event Vest(address indexed account, uint256 indexed streamId, uint256 amount);
}

error SablierV2Lockup_DepositAmountZero();
error SablierV2Lockup_StreamDepleted(uint256);

interface ISablierV2Lockup {
  function nextStreamId() external view returns (uint256);

  function withdraw(uint256 streamId, address to, uint128 amount) external;

  function withdrawMax(uint256 streamId, address to) external;

  function wasCanceled(uint256 streamId) external view returns (bool result);

  function withdrawableAmountOf(uint256 streamId) external view returns (uint128 withdrawableAmount);
}
