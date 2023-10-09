// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { VotePreviewer, IERC20, IPool, IExtraLending } from "../contracts/periphery/VotePreviewer.sol";
import { ForkTest } from "./Fork.t.sol";

contract VotePreviewerTest is ForkTest {
  using FixedPointMathLib for uint256;

  address internal exa;
  IPool internal pool;
  IERC20 internal gauge;
  IExtraLending internal extraLending;
  VotePreviewer internal previewer;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 110_504_307);

    exa = deployment("EXA");
    pool = IPool(deployment("EXAPool"));
    gauge = IERC20(deployment("EXAGauge"));
    extraLending = IExtraLending(deployment("ExtraLending"));
    previewer = VotePreviewer(
      address(new ERC1967Proxy(address(new VotePreviewer(exa, pool, gauge, extraLending, 50)), ""))
    );
  }

  function testExternalVotes() external {
    assertEq(previewer.externalVotes(0x23fD464e0b0eE21cEdEb929B19CABF9bD5215019), 27401932247383718289362);
  }
}
