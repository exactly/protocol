// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Auditor, ERC20, Market, RewardsController } from "../Market.sol";

contract VerifiedMarket is Market {
  constructor(ERC20 _asset, Auditor _auditor) Market(_asset, _auditor) {}

  function handleRewards(bool, address) internal override {} // solhint-disable-line no-empty-blocks

  function setRewardsController(RewardsController) public override {} // solhint-disable-line no-empty-blocks

  function rewardsController() external pure override returns (RewardsController) {
    return RewardsController(address(0));
  }
}
