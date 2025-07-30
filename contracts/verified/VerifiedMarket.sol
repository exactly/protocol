// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { ERC20, Market, RewardsController } from "../Market.sol";
import { NotAllowed, VerifiedAuditor } from "./VerifiedAuditor.sol";

contract VerifiedMarket is Market {
  constructor(ERC20 _asset, VerifiedAuditor _auditor) Market(_asset, _auditor) {}

  function depositAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired,
    address receiver
  ) public override returns (uint256) {
    if (!isAllowed(msg.sender)) revert NotAllowed(msg.sender);
    if (!isAllowed(receiver)) revert NotAllowed(receiver);

    return super.depositAtMaturity(maturity, assets, minAssetsRequired, receiver);
  }

  function withdrawAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 minAssetsRequired,
    address receiver,
    address owner
  ) public override returns (uint256 assetsDiscounted) {
    if (!isAllowed(owner)) revert NotAllowed(owner);
    return super.withdrawAtMaturity(maturity, positionAssets, minAssetsRequired, receiver, owner);
  }

  function handleRewards(bool, address) internal override {} // solhint-disable-line no-empty-blocks

  function isAllowed(address account) internal view returns (bool) {
    return VerifiedAuditor(address(auditor)).firewall().isAllowed(account);
  }

  function setRewardsController(RewardsController) public override {} // solhint-disable-line no-empty-blocks

  function rewardsController() external pure override returns (RewardsController) {
    return RewardsController(address(0));
  }
}
