// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { WETH } from "@rari-capital/solmate-v6/src/tokens/WETH.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FixedLender, IEToken, IAuditor, IPoolAccounting } from "./FixedLender.sol";

contract ETHFixedLender is FixedLender {
  bool private wrapOnOurSide = false;
  WETH private weth;

  modifier usingETH() {
    wrapOnOurSide = true;
    _;
    wrapOnOurSide = false;
  }

  constructor(
    WETH _token,
    string memory _underlyingTokenSymbol,
    IEToken _eToken,
    IAuditor _auditor,
    IPoolAccounting _poolAccounting
  ) FixedLender(IERC20(address(_token)), _underlyingTokenSymbol, _eToken, _auditor, _poolAccounting) {
    weth = _token;
  }

  // solhint-disable-next-line no-empty-blocks
  receive() external payable {}

  function borrowFromMaturityPoolEth(uint256 maturityDate, uint256 maxAmountAllowed) external payable usingETH {
    borrowFromMaturityPool(msg.value, maturityDate, maxAmountAllowed);
  }

  function depositToMaturityPoolEth(uint256 maturityDate, uint256 minAmountRequired) external payable usingETH {
    depositToMaturityPool(msg.value, maturityDate, minAmountRequired);
  }

  function depositToSmartPoolEth() external payable usingETH {
    depositToSmartPool(msg.value);
  }

  function withdrawFromSmartPoolEth(uint256 amount) external usingETH {
    withdrawFromSmartPool(amount);
  }

  function withdrawFromMaturityPoolEth(
    uint256 redeemAmount,
    uint256 minAmountRequired,
    uint256 maturityDate
  ) external usingETH {
    withdrawFromMaturityPool(redeemAmount, minAmountRequired, maturityDate);
  }

  function repayToMaturityPoolEth(address borrower, uint256 maturityDate) external payable usingETH {
    // TODO: how do you do slippage on bare ETH
    repayToMaturityPool(borrower, maturityDate, msg.value, msg.value);
  }

  function doTransferIn(address from, uint256 amount) internal override {
    if (wrapOnOurSide) {
      weth.deposit{ value: msg.value }();
    } else {
      super.doTransferIn(from, amount);
    }
  }

  function doTransferOut(address to, uint256 amount) internal override {
    if (wrapOnOurSide) {
      weth.withdraw(amount);
      payable(to).transfer(amount);
    } else {
      super.doTransferOut(to, amount);
    }
  }
}
