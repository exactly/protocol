// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { WETH, SafeTransferLib } from "@rari-capital/solmate/src/tokens/WETH.sol";
import { FixedLender, IAuditor, IPoolAccounting } from "./FixedLender.sol";

contract ETHFixedLender is FixedLender {
  using SafeTransferLib for address;

  bool private wrap = false;

  modifier usingETH() {
    wrap = true;
    _;
    wrap = false;
  }

  constructor(
    WETH weth,
    string memory assetSymbol_,
    IAuditor auditor_,
    IPoolAccounting poolAccounting_
  ) FixedLender(weth, assetSymbol_, auditor_, poolAccounting_) {} // solhint-disable-line no-empty-blocks

  receive() external payable {} // solhint-disable-line no-empty-blocks

  function borrowFromMaturityPoolETH(uint256 maturityDate, uint256 maxAmountAllowed) external payable usingETH {
    borrowFromMaturityPool(msg.value, maturityDate, maxAmountAllowed);
  }

  function depositToMaturityPoolETH(uint256 maturityDate, uint256 minAmountRequired) external payable usingETH {
    depositToMaturityPool(msg.value, maturityDate, minAmountRequired);
  }

  function depositETH(address receiver) public payable returns (uint256 shares) {
    // check for rounding error since we round down in previewDeposit.
    require((shares = previewDeposit(msg.value)) != 0, "ZERO_SHARES");

    WETH(payable(address(asset))).deposit{ value: msg.value }();

    _mint(receiver, shares);

    emit Deposit(msg.sender, receiver, msg.value, shares);

    afterDeposit(msg.value, shares);
  }

  function withdrawETH(
    uint256 assets,
    address receiver,
    address owner
  ) external returns (uint256 shares) {
    shares = previewWithdraw(assets); // no need to check for rounding error, previewWithdraw rounds up.

    if (msg.sender != owner) {
      uint256 allowed = allowance[owner][msg.sender]; // saves gas for limited approvals.

      if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
    }

    beforeWithdraw(assets, shares);

    _burn(owner, shares);

    emit Withdraw(msg.sender, receiver, owner, assets, shares);

    WETH(payable(address(asset))).withdraw(assets);
    receiver.safeTransferETH(assets);
  }

  function withdrawFromMaturityPoolETH(
    uint256 redeemAmount,
    uint256 minAmountRequired,
    uint256 maturityDate
  ) external usingETH {
    withdrawFromMaturityPool(redeemAmount, minAmountRequired, maturityDate);
  }

  function repayToMaturityPoolETH(
    address borrower,
    uint256 maturityDate,
    uint256 maxAmountAllowed
  ) external payable usingETH {
    repayToMaturityPool(borrower, maturityDate, msg.value, maxAmountAllowed);
  }

  function doTransferIn(address from, uint256 amount) internal override {
    if (wrap) {
      WETH(payable(address(asset))).deposit{ value: msg.value }();
    } else {
      super.doTransferIn(from, amount);
    }
  }

  function doTransferOut(address to, uint256 amount) internal override {
    if (wrap) {
      WETH(payable(address(asset))).withdraw(amount);
      payable(to).transfer(amount);
    } else {
      super.doTransferOut(to, amount);
    }
  }
}
