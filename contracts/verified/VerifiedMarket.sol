// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { ERC20, Market } from "../Market.sol";
import { VerifiedAuditor } from "./VerifiedAuditor.sol";

contract VerifiedMarket is Market {
  constructor(ERC20 asset_, VerifiedAuditor auditor_) Market(asset_, auditor_) {}

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

  function isAllowed(address account) internal view returns (bool) {
    return VerifiedAuditor(address(auditor)).firewall().isAllowed(account);
  }
}

error NotAllowed(address account);
