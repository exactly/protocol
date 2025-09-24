// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/access/AccessControlUpgradeable.sol";
import { Auditor, MarketNotListed } from "../Auditor.sol";
import { IFlashLoanRecipient, Market } from "../Market.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";

contract FlashLoanAdapter is AccessControlUpgradeable, IFlashLoanRecipient {
  Auditor public immutable auditor;
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_) {
    auditor = auditor_;

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize() external initializer {
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  function flashLoan(
    IFlashLoanAdapterRecipient recipient,
    ERC20[] memory tokens,
    uint256[] memory amounts,
    bytes calldata userData
  ) external {
    assert(tokens.length == 1 && amounts.length == 1);

    Market market = _getMarket(tokens[0]);
    bytes memory data = abi.encode(recipient, userData);

    // TODO compare gas using data and data2
    // bytes memory data2 = bytes.concat(abi.encodePacked(recipient), userData);

    market.flashLoan(IFlashLoanRecipient(address(this)), amounts[0], data);
  }

  function receiveFlashLoan(uint256 amount, bytes calldata data) external {
    Market market = Market(msg.sender);
    _checkMarket(market);

    // TODO compare gas using recipient2 and userData2
    // address recipient2 = data[0:20]; // check usage on plugin
    // bytes memory userData2 = data[20:];

    (IFlashLoanAdapterRecipient recipient, bytes memory userData) = abi.decode(
      data,
      (IFlashLoanAdapterRecipient, bytes)
    );

    ERC20[] memory tokens = new ERC20[](1);
    tokens[0] = market.asset();
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    recipient.receiveFlashLoan(tokens, amounts, new uint256[](1), userData);
  }

  function _checkMarket(Market market) internal view {
    (, , , bool listed, ) = auditor.markets(market);
    if (!listed) revert MarketNotListed();
  }

  function _getMarket(ERC20 token) internal view returns (Market) {
    Market[] memory markets = auditor.allMarkets();
    for (uint256 i = 0; i < markets.length; ++i) {
      if (markets[i].asset() == token) return markets[i];
    }
    revert MarketNotListed();
  }
}

interface IFlashLoanAdapterRecipient {
  function receiveFlashLoan(
    ERC20[] memory tokens,
    uint256[] memory amounts,
    uint256[] memory feesAmounts,
    bytes memory data
  ) external;
}
