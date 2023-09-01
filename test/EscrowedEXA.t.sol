// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ForkTest, stdError } from "./Fork.t.sol";
import { EXA, EscrowedEXA, ISablierV2LockupLinear } from "../contracts/periphery/EscrowedEXA.sol";

contract EscrowedEXATest is ForkTest {
  using FixedPointMathLib for uint256;

  EXA internal exa;
  EscrowedEXA internal escrowedEXA;
  ISablierV2LockupLinear internal sablier;
  address internal constant ALICE = address(0x420);

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 108_911_300);

    exa = EXA(deployment("EXA"));
    sablier = ISablierV2LockupLinear(deployment("SablierV2LockupLinear"));
    escrowedEXA = EscrowedEXA(
      address(
        new ERC1967Proxy(
          address(new EscrowedEXA(exa, sablier)),
          abi.encodeCall(EscrowedEXA.initialize, (6 * 4 weeks, 1e17))
        )
      )
    );

    vm.prank(deployment("TimelockController"));
    exa.transfer(address(this), 100_000 ether);
  }

  function testMint() external {
    exa.approve(address(escrowedEXA), 1_000 ether);
    escrowedEXA.mint(1_000 ether);
    assertEq(escrowedEXA.balanceOf(address(this)), 1_000 ether);
  }

  function testMintMoreThanBalance() external {
    exa.approve(address(escrowedEXA), 1_000_000 ether);
    vm.expectRevert(bytes(""));
    escrowedEXA.mint(1_000_000 ether);
  }

  function testMintZero() external {
    vm.expectRevert(stdError.assertionError);
    escrowedEXA.mint(0);
  }

  function testVest() external {
    uint256 amount = 1_000 ether;
    uint256 reserve = amount.mulWadDown(escrowedEXA.reserveFee());

    exa.approve(address(escrowedEXA), amount + reserve);
    escrowedEXA.mint(amount);
    uint256 exaBefore = exa.balanceOf(address(this));
    uint256 nextStreamId = ISablierV2Lockup(address(sablier)).nextStreamId();
    vm.expectEmit(true, true, true, true, address(escrowedEXA));
    emit Vest(address(this), nextStreamId, amount);
    uint256 streamId = escrowedEXA.vest(uint128(amount));

    assertEq(exaBefore, exa.balanceOf(address(this)) + reserve, "exa balance of sender -= reserve");
    assertEq(exa.balanceOf(address(escrowedEXA)), reserve, "exa balance of escrowedEXA == reserve");
    assertGt(streamId, 0);
    assertEq(streamId, nextStreamId);
  }

  function testVestAndCancel() external {
    uint256 amount = 1_000 ether;
    uint256 reserve = amount.mulWadDown(escrowedEXA.reserveFee());
    exa.approve(address(escrowedEXA), amount + reserve);
    escrowedEXA.mint(amount);

    uint256 streamId = escrowedEXA.vest(uint128(amount));
    vm.warp(block.timestamp + escrowedEXA.vestingPeriod() / 2);
    assertEq(ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streamId), amount / 2);
    assertFalse(ISablierV2Lockup(address(sablier)).wasCanceled(streamId), "stream is not canceled");
    assertEq(exa.balanceOf(address(escrowedEXA)), reserve, "exa.balanceOf(escrowedEXA) == reserve + amount");

    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId;

    uint256 remainingesEXA = amount / 2; // half period passed
    reserve = (amount + remainingesEXA).mulWadDown(escrowedEXA.reserveFee());
    exa.approve(address(escrowedEXA), amount + reserve);
    escrowedEXA.mint(amount);

    uint256 newStreamId = escrowedEXA.vest(uint128(amount), streamIds);

    assertEq(exa.balanceOf(address(escrowedEXA)), reserve, "exa.balanceOf(escrowedEXA) == reserve + amount");
    assertEq(newStreamId, streamId + 1);
    assertTrue(ISablierV2Lockup(address(sablier)).wasCanceled(streamId));
    ISablierV2Lockup(address(sablier)).withdrawMax(streamId, address(this));

    vm.warp(block.timestamp + 5 days);
    assertEq(ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streamId), 0);
    assertGt(ISablierV2Lockup(address(sablier)).withdrawableAmountOf(newStreamId), 0);
  }

  function testVestAndCancelWithInvalidAccount() external {
    exa.approve(address(escrowedEXA), 2_100 ether);
    escrowedEXA.mint(2_000 ether);
    uint256 streamId = escrowedEXA.vest(1_000 ether);

    vm.warp(block.timestamp + 1 days);
    assertGt(ISablierV2Lockup(address(sablier)).withdrawableAmountOf(streamId), 0);
    assertFalse(ISablierV2Lockup(address(sablier)).wasCanceled(streamId));

    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId;
    vm.prank(ALICE);
    vm.expectRevert(stdError.assertionError);
    escrowedEXA.vest(1_000 ether, streamIds);
  }

  function testVestZero() external {
    vm.expectRevert(SablierV2Lockup_DepositAmountZero.selector);
    escrowedEXA.vest(0);
  }

  function testSetVestingPeriodAsAdmin() external {
    uint40 newPeriod = 4 weeks;
    vm.expectEmit(true, true, true, true, address(escrowedEXA));
    emit VestingPeriodSet(newPeriod);
    escrowedEXA.setVestingPeriod(newPeriod);
    assertEq(escrowedEXA.vestingPeriod(), newPeriod);
  }

  function testSetVestingPeriodAsNotAdmin() external {
    vm.startPrank(ALICE);
    vm.expectRevert(bytes(""));
    escrowedEXA.setVestingPeriod(4 weeks);
  }

  function testSetAllowListAsAdmin() external {
    vm.expectEmit(true, true, false, true, address(escrowedEXA));
    emit TransferAllowed(ALICE, true);
    escrowedEXA.allowTransfer(ALICE, true);
    assertTrue(escrowedEXA.allowlist(ALICE));
  }

  function testSetAllowListAsNotAdmin() external {
    vm.startPrank(ALICE);
    vm.expectRevert(bytes(""));
    escrowedEXA.allowTransfer(ALICE, true);
  }

  function testTransferToAllowListed() external {
    exa.approve(address(escrowedEXA), 1 ether);
    escrowedEXA.mint(1 ether);

    escrowedEXA.allowTransfer(ALICE, true);
    escrowedEXA.transfer(ALICE, 1 ether);
    assertEq(escrowedEXA.balanceOf(ALICE), 1 ether);
  }

  function testTransferToNotAllowListed() external {
    vm.expectRevert(bytes(""));
    escrowedEXA.transfer(ALICE, 1 ether);
  }

  function testSetReserveFeeAsAdmin() external {
    uint256 newFee = 5e16;
    vm.expectEmit(true, true, true, true, address(escrowedEXA));
    emit ReserveFeeSet(newFee);
    escrowedEXA.setReserveFee(newFee);
    assertEq(escrowedEXA.reserveFee(), newFee);
  }

  function testSetReserveFeeAsNotAdmin() external {
    vm.startPrank(ALICE);
    vm.expectRevert(bytes(""));
    escrowedEXA.setReserveFee(5e16);
  }

  function testCancelShouldGiveReservesBack() external {
    uint256 initialAmount = 1_000 ether;
    uint256 reserve = initialAmount.mulWadDown(escrowedEXA.reserveFee());
    exa.approve(address(escrowedEXA), initialAmount * 2);
    escrowedEXA.mint(initialAmount * 2);

    uint256 initialEXA = exa.balanceOf(address(this));

    exa.approve(address(escrowedEXA), reserve);
    uint256 streamId1 = escrowedEXA.vest(uint128(initialAmount));
    assertEq(exa.balanceOf(address(this)), initialEXA - reserve);

    exa.approve(address(escrowedEXA), reserve);
    uint256 streamId2 = escrowedEXA.vest(uint128(initialAmount));
    assertEq(exa.balanceOf(address(this)), initialEXA - reserve * 2);

    vm.warp(block.timestamp + escrowedEXA.vestingPeriod() / 2);

    uint256[] memory streamIds = new uint256[](2);
    streamIds[0] = streamId1;
    streamIds[1] = streamId2;
    escrowedEXA.cancel(streamIds);

    assertEq(exa.balanceOf(address(this)), initialEXA, "should give reserves back");
  }

  function testCancelWithInvalidAccount() external {
    uint256 initialAmount = 1_000 ether;
    uint256 reserve = initialAmount.mulWadDown(escrowedEXA.reserveFee());
    exa.approve(address(escrowedEXA), initialAmount);
    escrowedEXA.mint(initialAmount);

    uint256 initialEXA = exa.balanceOf(address(this));

    exa.approve(address(escrowedEXA), reserve);
    uint256 streamId1 = escrowedEXA.vest(uint128(initialAmount));
    assertEq(exa.balanceOf(address(this)), initialEXA - reserve);

    vm.warp(block.timestamp + escrowedEXA.vestingPeriod() / 2);

    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId1;
    vm.prank(ALICE);
    vm.expectRevert(stdError.assertionError);
    escrowedEXA.cancel(streamIds);
  }

  function testVestAndCancelHigherStream() external {
    uint256 initialAmount = 1_000 ether;
    uint256 reserve = initialAmount.mulWadDown(escrowedEXA.reserveFee());
    exa.approve(address(escrowedEXA), initialAmount + reserve);
    escrowedEXA.mint(initialAmount);
    uint256 streamId = escrowedEXA.vest(uint128(initialAmount));

    vm.warp(block.timestamp + escrowedEXA.vestingPeriod() / 2);

    uint256 newAmount = 100 ether;
    uint256 newReserve = newAmount.mulWadDown(escrowedEXA.reserveFee());
    exa.approve(address(escrowedEXA), newAmount + newReserve);
    escrowedEXA.mint(newAmount);

    uint256 exaBefore = exa.balanceOf(address(this));
    uint256[] memory streamIds = new uint256[](1);
    streamIds[0] = streamId;
    escrowedEXA.vest(uint128(newAmount), streamIds);

    assertEq(exa.balanceOf(address(this)), exaBefore + reserve / 2 - newReserve);
    assertGt(exa.balanceOf(address(this)), exaBefore);
  }

  event ReserveFeeSet(uint256 reserveFee);
  event VestingPeriodSet(uint256 vestingPeriod);
  event TransferAllowed(address indexed account, bool allow);
  event Vest(address indexed account, uint256 indexed streamId, uint256 amount);
}

error SablierV2Lockup_DepositAmountZero();

interface ISablierV2Lockup {
  function nextStreamId() external view returns (uint256);

  function withdraw(uint256 streamId, address to, uint128 amount) external;

  function withdrawMax(uint256 streamId, address to) external;

  function wasCanceled(uint256 streamId) external view returns (bool result);

  function withdrawableAmountOf(uint256 streamId) external view returns (uint128 withdrawableAmount);
}
