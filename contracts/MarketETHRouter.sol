// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { WETH, SafeTransferLib } from "solmate/src/tokens/WETH.sol";
import { Market } from "./Market.sol";

/// @notice To be used by Exactly's web-app so accounts can operate with ETH on MarketWETH.
contract MarketETHRouter is Initializable {
  using SafeTransferLib for address;
  using SafeTransferLib for WETH;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Market public immutable market;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  WETH public immutable weth;

  modifier wrap() {
    weth.deposit{ value: msg.value }();
    _;
  }

  modifier unwrap(uint256 assets) {
    _;
    unwrapAndTransfer(assets);
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Market market_) {
    market = market_;
    weth = WETH(payable(address(market_.asset())));

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize() external initializer {
    weth.safeApprove(address(market), type(uint256).max);
  }

  /// @notice Receives ETH when unwrapping WETH.
  /// @dev Prevents other accounts from mistakenly sending ETH to this contract.
  receive() external payable {
    if (msg.sender != address(weth)) revert NotFromWETH();
  }

  /// @notice Wraps ETH and deposits WETH into the floating pool's market.
  /// @return shares number of minted shares.
  function deposit() external payable wrap returns (uint256 shares) {
    return market.deposit(msg.value, msg.sender);
  }

  /// @notice Unwraps WETH from the floating pool and withdraws to caller.
  /// @param assets amount of assets to withdraw.
  /// @return shares number of burned shares.
  function withdraw(uint256 assets) external unwrap(assets) returns (uint256 shares) {
    return market.withdraw(assets, address(this), msg.sender);
  }

  /// @notice Unwraps WETH from the floating pool and withdraws to caller.
  /// @param shares amount of shares to be burned in exchange of assets.
  /// @return assets amount of assets withdrawn.
  function redeem(uint256 shares) external returns (uint256 assets) {
    assets = market.redeem(shares, address(this), msg.sender);
    unwrapAndTransfer(assets);
  }

  /// @notice Unwraps WETH from the floating pool and borrows to caller.
  /// @param assets amount of assets to borrow.
  /// @return borrowShares number of borrowed shares.
  function borrow(uint256 assets) external unwrap(assets) returns (uint256 borrowShares) {
    return market.borrow(assets, address(this), msg.sender);
  }

  /// @notice Wraps ETH and repays to the floating pool.
  /// @param assets amount of assets to repay.
  /// @return repaidAssets number of repaid assets (can be lower than `assets`).
  /// @return borrowShares number of borrowed shares subtracted from the debt.
  function repay(uint256 assets) external payable wrap returns (uint256 repaidAssets, uint256 borrowShares) {
    (repaidAssets, borrowShares) = market.repay(assets, msg.sender);

    if (msg.value > repaidAssets) unwrapAndTransfer(msg.value - repaidAssets);
  }

  /// @notice Wraps ETH and repays to the floating pool.
  /// @param borrowShares shares to be subtracted from the caller's debt.
  /// @return repaidAssets number of repaid assets.
  /// @return actualShares number of borrowed shares subtracted from the debt (can be lower than `borrowShares`).
  function refund(uint256 borrowShares) external payable wrap returns (uint256 repaidAssets, uint256 actualShares) {
    (repaidAssets, actualShares) = market.refund(borrowShares, msg.sender);

    if (msg.value > repaidAssets) unwrapAndTransfer(msg.value - repaidAssets);
  }

  /// @notice Wraps ETH and deposits to a maturity.
  /// @param maturity maturity date where the assets will be deposited.
  /// @param minAssetsRequired minimum amount of assets required by the caller for the transaction to be accepted.
  /// @return maturityAssets total amount of assets (principal + fee) to be withdrawn at maturity.
  function depositAtMaturity(uint256 maturity, uint256 minAssetsRequired)
    external
    payable
    wrap
    returns (uint256 maturityAssets)
  {
    return market.depositAtMaturity(maturity, msg.value, minAssetsRequired, msg.sender);
  }

  /// @notice Unwraps WETH from a maturity and withdraws to caller.
  /// @param maturity maturity date where the assets will be withdrawn.
  /// @param assets position size to be reduced.
  /// @param minAssetsRequired minimum amount required by the caller (if discount included for early withdrawal).
  /// @return actualAssets amount of assets withdrawn (can include a discount for early withdraw).
  function withdrawAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired
  ) external returns (uint256 actualAssets) {
    actualAssets = market.withdrawAtMaturity(maturity, assets, minAssetsRequired, address(this), msg.sender);
    unwrapAndTransfer(actualAssets);
  }

  /// @notice Unwraps WETH from a maturity and borrows to caller.
  /// @param maturity maturity date for repayment.
  /// @param assets amount to be sent to caller.
  /// @param maxAssetsAllowed maximum amount of debt that the caller is willing to accept.
  /// @return assetsOwed total amount of assets (principal + fee) to be repaid at maturity.
  function borrowAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 maxAssetsAllowed
  ) external unwrap(assets) returns (uint256 assetsOwed) {
    return market.borrowAtMaturity(maturity, assets, maxAssetsAllowed, address(this), msg.sender);
  }

  /// @notice Wraps ETH and repays to a maturity.
  /// @param maturity maturity date where the assets will be repaid.
  /// @param assets amount to be paid for the caller's debt.
  /// @return repaidAssets the actual amount that was transferred into the Market.
  function repayAtMaturity(uint256 maturity, uint256 assets) external payable wrap returns (uint256 repaidAssets) {
    repaidAssets = market.repayAtMaturity(maturity, assets, msg.value, msg.sender);

    if (msg.value > repaidAssets) unwrapAndTransfer(msg.value - repaidAssets);
  }

  function unwrapAndTransfer(uint256 assets) internal {
    weth.withdraw(assets);
    msg.sender.safeTransferETH(assets);
  }
}

error NotFromWETH();
