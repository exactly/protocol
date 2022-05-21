// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { WETH, SafeTransferLib } from "@rari-capital/solmate/src/tokens/WETH.sol";
import { FixedLender } from "./FixedLender.sol";

contract FixedLenderETHRouter {
  using SafeTransferLib for address;

  FixedLender public immutable fixedLender;
  WETH public immutable weth;

  modifier wrap() {
    weth.deposit{ value: msg.value }();
    _;
  }

  modifier unwrap(uint256 assets, address receiver) {
    _;
    unwrapAndTransfer(assets, receiver);
  }

  constructor(FixedLender fixedLender_) {
    fixedLender = fixedLender_;
    weth = WETH(payable(address(fixedLender_.asset())));
    weth.approve(address(fixedLender_), type(uint256).max);
  }

  receive() external payable {
    if (msg.sender != address(weth)) revert NotFromWETH();
  }

  function depositETH() public payable wrap returns (uint256 shares) {
    shares = fixedLender.deposit(msg.value, msg.sender);
  }

  function withdrawETH(uint256 assets) external unwrap(assets, msg.sender) returns (uint256 shares) {
    shares = fixedLender.withdraw(assets, address(this), msg.sender);
  }

  function depositAtMaturityETH(uint256 maturity, uint256 minAssetsRequired)
    external
    payable
    wrap
    returns (uint256 maturityAssets)
  {
    return fixedLender.depositAtMaturity(maturity, msg.value, minAssetsRequired, msg.sender);
  }

  function withdrawAtMaturityETH(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired
  ) external returns (uint256 actualAssets) {
    actualAssets = fixedLender.withdrawAtMaturity(maturity, assets, minAssetsRequired, address(this), msg.sender);
    unwrapAndTransfer(actualAssets, msg.sender);
  }

  function borrowAtMaturityETH(
    uint256 maturity,
    uint256 assets,
    uint256 maxAssetsAllowed
  ) external unwrap(assets, msg.sender) returns (uint256 assetsOwed) {
    return fixedLender.borrowAtMaturity(maturity, assets, maxAssetsAllowed, address(this), msg.sender);
  }

  function repayAtMaturityETH(uint256 maturity, uint256 assets) external payable wrap returns (uint256 repaidAssets) {
    repaidAssets = fixedLender.repayAtMaturity(maturity, assets, msg.value, msg.sender);

    if (msg.value > repaidAssets) unwrapAndTransfer(msg.value - repaidAssets, msg.sender);
  }

  function unwrapAndTransfer(uint256 assets, address receiver) internal {
    weth.withdraw(assets);
    receiver.safeTransferETH(assets);
  }
}

error NotFromWETH();
