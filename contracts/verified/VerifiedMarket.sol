// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { ERC20, Market } from "../Market.sol";
import { NotAllowed, VerifiedAuditor } from "./VerifiedAuditor.sol";

contract VerifiedMarket is Market {
  constructor(ERC20 asset_, VerifiedAuditor auditor_) Market(asset_, auditor_) {}

  function deposit(
    uint256 assets,
    address receiver
  ) public override onlyAllowed(msg.sender) onlyAllowed(receiver) returns (uint256 shares) {
    return super.deposit(assets, receiver);
  }

  function mint(
    uint256 shares,
    address receiver
  ) public override onlyAllowed(msg.sender) onlyAllowed(receiver) returns (uint256 assets) {
    return super.mint(shares, receiver);
  }

  function depositAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired,
    address receiver
  ) public override onlyAllowed(msg.sender) onlyAllowed(receiver) returns (uint256) {
    return super.depositAtMaturity(maturity, assets, minAssetsRequired, receiver);
  }

  function liquidate(
    address borrower,
    uint256 maxAssets,
    Market seizeMarket
  ) public override onlyAllowed(msg.sender) returns (uint256 repaidAssets) {
    return super.liquidate(borrower, maxAssets, seizeMarket);
  }

  function transfer(address to, uint256 shares) public override onlyAllowed(to) returns (bool) {
    return super.transfer(to, shares);
  }

  function transferFrom(address from, address to, uint256 shares) public override onlyAllowed(to) returns (bool) {
    return super.transferFrom(from, to, shares);
  }

  function withdrawAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 minAssetsRequired,
    address receiver,
    address owner
  ) public override onlyAllowed(owner) returns (uint256 assetsDiscounted) {
    return super.withdrawAtMaturity(maturity, positionAssets, minAssetsRequired, receiver, owner);
  }

  function _requireAllowed(address account) internal view {
    if (!VerifiedAuditor(address(auditor)).firewall().isAllowed(account)) revert NotAllowed(account);
  }


  modifier onlyAllowed(address account) {
    _requireAllowed(account);
    _;
  }
}
