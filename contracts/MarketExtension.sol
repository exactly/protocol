// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC4626, ERC20 } from "solmate/src/mixins/ERC4626.sol";

import { MarketBase } from "./MarketBase.sol";

contract MarketExtension is MarketBase {
  constructor(ERC20 asset_) ERC4626(asset_, "", "") {
    _disableInitializers();
  }
}
