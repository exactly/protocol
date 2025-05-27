// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { BaseScript } from "./Base.s.sol";
import { Auditor } from "../contracts/Auditor.sol";
import { ERC20, Market } from "../contracts/Market.sol";
import { RewardsController } from "../contracts/RewardsController.sol";

/// @notice calls initConsolidated for all accounts in all markets
/// @dev runs with a fixed block where upgrades haven't happened yet
contract InitializeAccountsScript is BaseScript {
  RewardsController internal rewardsController;
  Auditor internal auditor;
  address internal exampleAccount;
  Market internal exaUSDC;
  Market internal exaUSDCe;
  Market internal exaWETH;
  Market internal exawstETH;
  Market internal exaOP;
  Market internal exaWBTC;
  ERC20 internal esEXA;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 136_380_000);
    auditor = Auditor(deployment("Auditor"));
    rewardsController = RewardsController(deployment("RewardsController"));
    exaUSDC = Market(deployment("MarketUSDC"));
    exaUSDCe = Market(deployment("MarketUSDC.e"));
    exaWETH = Market(deployment("MarketWETH"));
    exawstETH = Market(deployment("MarketwstETH"));
    exaOP = Market(deployment("MarketOP"));
    exaWBTC = Market(deployment("MarketWBTC"));
    esEXA = ERC20(deployment("esEXA"));

    upgrade(address(exaUSDC), address(new Market(exaUSDC.asset(), exaUSDC.auditor())));
    upgrade(address(exaUSDCe), address(new Market(exaUSDCe.asset(), exaUSDCe.auditor())));
    upgrade(address(exaWETH), address(new Market(exaWETH.asset(), exaWETH.auditor())));
    upgrade(address(exawstETH), address(new Market(exawstETH.asset(), exawstETH.auditor())));
    upgrade(address(exaOP), address(new Market(exaOP.asset(), exaOP.auditor())));
    upgrade(address(exaWBTC), address(new Market(exaWBTC.asset(), exaWBTC.auditor())));

    upgrade(address(rewardsController), address(new RewardsController()));
  }

  function run() external {
    string memory json = vm.readFile("./scripts/accounts.json");
    address[] memory accounts = abi.decode(vm.parseJson(json), (address[]));
    Market[] memory allMarkets = auditor.allMarkets();

    for (uint i = 0; i < accounts.length; ++i) {
      emit log_named_address("    account", accounts[i]);
      for (uint j = 0; j < allMarkets.length; ++j) {
        allMarkets[j].initConsolidated(accounts[i]);
        emit log_named_string("initialized", allMarkets[j].symbol());
      }
    }
  }
}
