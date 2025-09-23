// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/access/AccessControlUpgradeable.sol";
import { Auditor, MarketNotListed } from "../Auditor.sol";
import { IFlashLoanRecipient, Market } from "../Market.sol";
import { ReentrancyGuard } from "solmate/src/utils/ReentrancyGuard.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";

contract FlashLoanAdapter is AccessControlUpgradeable, IFlashLoanRecipient, ReentrancyGuard {
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
    IFlashLoanRecipientRename recipient,
    ERC20[] memory tokens,
    uint256[] memory amounts,
    bytes memory userData
  ) external nonReentrant {
    assert(tokens.length == 1 && amounts.length == 1);

    Market market = _getMarket(tokens[0]);
    bytes memory data = abi.encode(recipient, userData);
    market.flashLoan(IFlashLoanRecipient(address(this)), amounts[0], data);
  }

  function receiveFlashLoan(uint256 amount, bytes memory data) external {
    Market market = Market(msg.sender);
    _checkMarket(market);
    (IFlashLoanRecipientRename recipient, bytes memory userData) = abi.decode(data, (IFlashLoanRecipientRename, bytes));

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

interface IFlashLoanRecipientRename {
  function receiveFlashLoan(ERC20[] memory tokens, uint256[] memory amounts, uint256[] memory feesAmounts, bytes memory data) external;
}
