// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.17;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { BaseScript, stdJson } from "./Base.s.sol";
import { RewardsController, ERC20 } from "../contracts/RewardsController.sol";

contract AirdropScript is BaseScript {
  using FixedPointMathLib for uint256;
  using Strings for uint256;
  using Strings for address;
  using stdJson for string;

  uint256 internal constant DISTRIBUTION = 100_000e18;

  mapping(address => uint256) public rewards;

  function run() external {
    if (vm.envOr("AIRDROP_FETCH_ACCOUNTS", true)) {
      string[] memory node = new string[](3);
      node[0] = "npx";
      node[1] = "ts-node";
      node[2] = "scripts/airdrop.ts";
      vm.ffi(node);
    }

    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 107_054_000);
    ERC20 op = ERC20(deployment("OP"));
    string memory claimedJson = vm.readFile("scripts/claimed.json");
    address[] memory accounts = vm.readFile("scripts/accounts.json").readAddressArray("");
    RewardsController rewardsController = RewardsController(deployment("RewardsController"));

    uint256 totalRewards = 0;
    for (uint256 i = 0; i < accounts.length; ++i) {
      uint256 claimed = claimedJson.readUint(string.concat(".", accounts[i].toHexString()));
      uint256 claimable = rewardsController.allClaimable(accounts[i], op);
      totalRewards += claimed + claimable;
      rewards[accounts[i]] = claimed + claimable;
    }

    string memory json;
    string memory airdrop = "airdrop";
    for (uint256 i = 0; i < accounts.length; ++i) {
      uint256 amount = rewards[accounts[i]].mulDivDown(DISTRIBUTION, totalRewards);
      if (amount == 0) continue;
      json = airdrop.serialize(accounts[i].toHexString(), string.concat('"', amount.toString(), '"'));
    }
    json.write("scripts/airdrop.json");
  }
}
