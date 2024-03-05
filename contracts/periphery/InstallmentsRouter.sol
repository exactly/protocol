// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { WETH, SafeTransferLib } from "solmate/src/tokens/WETH.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import {
  SafeERC20Upgradeable as SafeERC20,
  IERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { Auditor, MarketNotListed } from "../Auditor.sol";
import { Market, ERC20, FixedLib } from "../Market.sol";

/// @title InstallmentsRouter.
/// @notice Router to make many borrows on a specific market with a single transaction.
contract InstallmentsRouter {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for address;
  using SafeTransferLib for ERC20;
  using SafeERC20 for IERC20PermitUpgradeable;

  /// @notice Auditor contract that lists the markets that can be borrowed.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;
  /// @notice Market for the WETH asset.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Market public immutable marketWETH;
  /// @notice WETH token.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  WETH public immutable weth;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_, Market marketWETH_) {
    auditor = auditor_;
    marketWETH = marketWETH_;
    weth = address(marketWETH_) != address(0) ? WETH(payable(address(marketWETH_.asset()))) : WETH(payable(0));
  }

  /// @notice Receives ETH when unwrapping WETH.
  /// @dev Prevents other accounts from mistakenly sending ETH to this contract.
  receive() external payable {
    if (msg.sender != address(weth)) revert NotFromWETH();
  }

  /// @notice Borrows assets from a Market in the subsequent maturities.
  /// @param market The Market to borrow from.
  /// @param firstMaturity The first maturity to borrow from.
  /// @param amounts The amounts to borrow in each maturity.
  /// @param maxRepay The maximum amount of assets to repay.
  /// @return assetsOwed The amount of assets owed for each maturity.
  function borrow(
    Market market,
    uint256 firstMaturity,
    uint256[] calldata amounts,
    uint256 maxRepay
  ) public returns (uint256[] memory assetsOwed) {
    return borrow(market, firstMaturity, amounts, maxRepay, msg.sender);
  }

  function borrow(
    Market market,
    uint256 firstMaturity,
    uint256[] calldata amounts,
    uint256 maxRepay,
    address receiver
  ) internal returns (uint256[] memory assetsOwed) {
    assert(amounts.length != 0 && firstMaturity > block.timestamp);
    checkMarket(market);

    assetsOwed = new uint256[](amounts.length);
    uint256 totalOwed;
    for (uint256 i = 0; i < amounts.length; i++) {
      uint256 owed = market.borrowAtMaturity(
        firstMaturity + i * FixedLib.INTERVAL,
        amounts[i],
        type(uint256).max,
        receiver,
        msg.sender
      );
      assetsOwed[i] = owed;
      totalOwed += owed;
    }
    if (totalOwed > maxRepay) revert Disagreement();
    emit Borrow(market, firstMaturity, amounts, assetsOwed, msg.sender);
  }

  /// @notice Borrows WETH from the WETH Market in the subsequent maturities.
  /// unwraps the WETH to transfer eth to msg.sender
  /// @param maturity The first maturity to borrow from.
  /// @param amounts The amounts to borrow in each maturity.
  /// @param maxRepay The maximum amount of assets to repay.
  /// @return assetsOwed The amount of assets owed for each maturity.
  function borrowETH(
    uint256 maturity,
    uint256[] calldata amounts,
    uint256 maxRepay
  ) public returns (uint256[] memory assetsOwed) {
    uint256 totalAmount = 0;
    for (uint256 i = 0; i < amounts.length; i++) totalAmount += amounts[i];
    assetsOwed = borrow(marketWETH, maturity, amounts, maxRepay, address(this));
    weth.withdraw(totalAmount);
    msg.sender.safeTransferETH(totalAmount);
  }

  function borrow(
    Market market,
    uint256 firstMaturity,
    uint256[] calldata amounts,
    uint256 maxRepay,
    Permit calldata marketPermit
  ) external permit(market, marketPermit) returns (uint256[] memory assetsOwed) {
    return borrow(market, firstMaturity, amounts, maxRepay);
  }

  function borrowETH(
    uint256 maturity,
    uint256[] calldata amounts,
    uint256 maxRepay,
    Permit calldata marketPermit
  ) public permit(marketWETH, marketPermit) returns (uint256[] memory assetsOwed) {
    assetsOwed = borrow(marketWETH, maturity, amounts, maxRepay, address(this));
    uint256 totalAmount = 0;
    for (uint256 i = 0; i < amounts.length; i++) totalAmount += amounts[i];
    weth.withdraw(totalAmount);
    msg.sender.safeTransferETH(totalAmount);
  }

  /// @notice Checks if the Market is listed by the Auditor.
  /// @param market The Market to check.
  function checkMarket(Market market) internal view {
    (, , , bool listed, ) = auditor.markets(market);
    if (!listed) revert MarketNotListed();
  }

  /// @notice Emitted when a borrow is made.
  /// @param market The Market that the borrow was made from.
  /// @param maturity The first maturity that the borrow was made from.
  /// @param amounts The amounts that were borrowed in each maturity.
  /// @param assetsOwed The amount of assets owed for each maturity.
  /// @param borrower The address that made the borrow.
  event Borrow(Market market, uint256 maturity, uint256[] amounts, uint256[] assetsOwed, address indexed borrower);

  modifier wrap() {
    weth.deposit{ value: msg.value }();
    _;
  }

  /// @notice Calls `market.permit` on behalf of `msg.sender`.
  /// @param market The Market to call permit on.
  /// @param p Arguments for the permit call.
  modifier permit(Market market, Permit calldata p) {
    IERC20PermitUpgradeable(address(market)).safePermit(msg.sender, address(this), p.value, p.deadline, p.v, p.r, p.s);
    _;
  }
}

struct Permit {
  uint256 value;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}

error Disagreement();
error NotFromWETH();
