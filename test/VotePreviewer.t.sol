// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { VotePreviewer, IERC20, IPool, IBeefyVault, IExtraLending } from "../contracts/periphery/VotePreviewer.sol";
import { ForkTest } from "./Fork.t.sol";

contract VotePreviewerTest is ForkTest {
  using FixedPointMathLib for uint256;

  address internal exa;
  IPool internal pool;
  IERC20 internal gauge;
  IBeefyVault internal beefyVault;
  IERC20 internal beefyBoost;
  IExtraLending internal extraLending;
  VotePreviewer internal previewer;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 110_504_307);

    exa = deployment("EXA");
    pool = IPool(deployment("EXAPool"));
    gauge = IERC20(deployment("EXAGauge"));
    beefyVault = IBeefyVault(deployment("BeefyEXA"));
    beefyBoost = IERC20(deployment("BeefyEXABoost"));
    extraLending = IExtraLending(deployment("ExtraLending"));
    previewer = VotePreviewer(
      address(
        new ERC1967Proxy(address(new VotePreviewer(exa, pool, gauge, beefyVault, beefyBoost, extraLending, 50)), "")
      )
    );
    vm.label(address(previewer), "VotePreviewer");
  }

  function testExternalVotes() external {
    assertEq(previewer.externalVotes(0x23fD464e0b0eE21cEdEb929B19CABF9bD5215019), 27401932247383718289362);
    assertEq(previewer.externalVotes(0x1283D47A121f903D9BD73f0f8E83728c488969f5), 1559177426053281144);
    assertEq(previewer.externalVotes(0x4cd45E3Fef61079Ee67cbB9e9e230641A4Ae2f87), 368157682632212466);
  }
}
