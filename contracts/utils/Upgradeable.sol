// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

abstract contract Upgradeable is Initializable, UUPSUpgradeable {
  constructor() {
    _disableInitializers();
  }

  function initialize(address admin) internal onlyInitializing {
    _changeAdmin(admin);
  }

  function _authorizeUpgrade(address) internal view override {
    if (_getAdmin() != msg.sender) revert NotAdmin();
  }
}

error NotAdmin();
