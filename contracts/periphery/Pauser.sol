// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Auditor, Market } from "../Auditor.sol";

contract Pauser is Ownable {
  Auditor public immutable auditor;

  constructor(Auditor auditor_, address owner_) Ownable(owner_) {
    auditor = auditor_;
  }

  function pause() external onlyOwner {
    Market[] memory markets = auditor.allMarkets();
    bool success = false;
    for (uint256 i = 0; i < markets.length; ++i) {
      if (!markets[i].paused()) {
        success = true;
        markets[i].pause();
      }
    }
    assert(success);
  }
}
