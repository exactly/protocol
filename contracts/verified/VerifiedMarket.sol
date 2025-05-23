// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Auditor, ERC20, Market } from "../Market.sol";

contract VerifiedMarket is Market {
  constructor(ERC20 asset_, Auditor auditor_) Market(asset_, auditor_) {}
}
