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
        new ERC1967Proxy(address(new EscrowedEXA(exa, sablier)), abi.encodeCall(EscrowedEXA.initialize, (6 * 4 weeks)))
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
    vm.expectRevert();
    escrowedEXA.mint(1_000_000 ether);
  }

  function testMintZero() external {
    vm.expectRevert();
    escrowedEXA.mint(0);
  }

  function testVest() external {
    exa.approve(address(escrowedEXA), 1_000 ether);
    escrowedEXA.mint(1_000 ether);
    uint256 nextStreamId = ISablierV2Lockup(address(sablier)).nextStreamId();
    vm.expectEmit(true, true, true, true, address(escrowedEXA));
    emit Vest(address(this), nextStreamId, 1_000 ether);
    uint256 streamId = escrowedEXA.vest(1_000 ether);
    assertGt(streamId, 0);
    assertEq(streamId, nextStreamId);
  }

  function testVestZero() external {
    vm.expectRevert();
    escrowedEXA.vest(0);
  }

  function testSetVestingPeriodAsOwner() external {
    uint40 newPeriod = 4 weeks;
    vm.expectEmit(true, true, true, true, address(escrowedEXA));
    emit VestingPeriodSet(newPeriod);
    escrowedEXA.setVestingPeriod(newPeriod);
    assertEq(escrowedEXA.vestingPeriod(), newPeriod);
  }

  function testSetVestingPeriodAsNotOwner() external {
    vm.startPrank(ALICE);
    vm.expectRevert();
    escrowedEXA.setVestingPeriod(4 weeks);
  }

  function testSetAllowListAsOwner() external {
    vm.expectEmit(true, true, false, true, address(escrowedEXA));
    emit TransferAllowed(ALICE, true);
    escrowedEXA.allowTransfer(ALICE, true);
    assertTrue(escrowedEXA.allowlist(ALICE));
  }

  function testSetAllowListAsNotOwner() external {
    vm.startPrank(ALICE);
    vm.expectRevert();
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
    vm.expectRevert();
    escrowedEXA.transfer(ALICE, 1 ether);
  }

  event VestingPeriodSet(uint256 vestingPeriod);
  event TransferAllowed(address indexed account, bool allow);
  event Vest(address indexed account, uint256 indexed streamId, uint256 amount);
}

interface ISablierV2Lockup {
  function nextStreamId() external view returns (uint256);

  function withdraw(uint256 streamId, address to, uint128 amount) external;

  function withdrawMax(uint256 streamId, address to) external;
}
