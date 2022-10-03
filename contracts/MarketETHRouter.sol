// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.16;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { WETH, SafeTransferLib } from "solmate/src/tokens/WETH.sol";
import { Market } from "./Market.sol";

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

  function initialize() external initializer {
    weth.safeApprove(address(market), type(uint256).max);
  }

  receive() external payable {
    if (msg.sender != address(weth)) revert NotFromWETH();
  }

  function deposit() external payable wrap returns (uint256 shares) {
    shares = market.deposit(msg.value, msg.sender);
  }

  function withdraw(uint256 assets) external unwrap(assets) returns (uint256 shares) {
    shares = market.withdraw(assets, address(this), msg.sender);
  }

  function borrow(uint256 assets) external unwrap(assets) returns (uint256 borrowShares) {
    borrowShares = market.borrow(assets, address(this), msg.sender);
  }

  function repay(uint256 assets) external payable wrap returns (uint256 repaidAssets, uint256 borrowShares) {
    (repaidAssets, borrowShares) = market.repay(assets, msg.sender);

    if (msg.value > repaidAssets) unwrapAndTransfer(msg.value - repaidAssets);
  }

  function refund(uint256 borrowShares) external payable wrap returns (uint256 repaidAssets) {
    repaidAssets = market.refund(borrowShares, msg.sender);

    if (msg.value > repaidAssets) unwrapAndTransfer(msg.value - repaidAssets);
  }

  function depositAtMaturity(uint256 maturity, uint256 minAssetsRequired)
    external
    payable
    wrap
    returns (uint256 maturityAssets)
  {
    return market.depositAtMaturity(maturity, msg.value, minAssetsRequired, msg.sender);
  }

  function withdrawAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired
  ) external returns (uint256 actualAssets) {
    actualAssets = market.withdrawAtMaturity(maturity, assets, minAssetsRequired, address(this), msg.sender);
    unwrapAndTransfer(actualAssets);
  }

  function borrowAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 maxAssetsAllowed
  ) external unwrap(assets) returns (uint256 assetsOwed) {
    return market.borrowAtMaturity(maturity, assets, maxAssetsAllowed, address(this), msg.sender);
  }

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
