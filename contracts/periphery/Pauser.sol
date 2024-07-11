// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Auditor, Market } from "../Auditor.sol";

contract Pauser is Ownable {
  Auditor public immutable auditor;

  constructor(Auditor auditor_, address owner_) Ownable(owner_) {
    auditor = auditor_;
  }

  function pause(IPausable[] calldata targets) external onlyOwner {
    bool success = false;
    for (uint256 i = 0; i < targets.length; ++i) success = _pause(targets[i]) || success;
    assert(success);
  }

  function pauseProtocol(IPausable[] calldata extra) external onlyOwner {
    Market[] memory markets = auditor.allMarkets();
    bool success = false;
    for (uint256 i = 0; i < markets.length; ++i) success = _pause(IPausable(address(markets[i]))) || success;
    for (uint256 i = 0; i < extra.length; ++i) success = _pause(extra[i]) || success;
    assert(success);
  }

  function _pause(IPausable pausable) internal returns (bool) {
    if (pausable.paused()) return false;
    pausable.pause();
    return true;
  }
}

interface IPausable {
  function paused() external view returns (bool);
  function pause() external;
}
