// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "./FixedLender.sol";
import "./external/WETH9.sol";

contract ETHFixedLender is FixedLender {
    bool private wrapOnOurSide;
    WETH9 private weth;

    modifier usingETH() {
        wrapOnOurSide = true;
        _;
        wrapOnOurSide = false;
    }

    constructor(
        address payable _tokenAddress,
        string memory _underlyingTokenSymbol,
        address _eTokenAddress,
        address _auditorAddress,
        address _poolAccounting
    )
        FixedLender(
            _tokenAddress,
            _underlyingTokenSymbol,
            _eTokenAddress,
            _auditorAddress,
            _poolAccounting
        )
    {
        // just to be explicit uwu I know it is zero/falsy by default
        wrapOnOurSide = false;
        weth = WETH9(_tokenAddress);
    }

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    function borrowFromMaturityPoolEth(
        uint256 maturityDate,
        uint256 maxAmountAllowed
    ) external payable usingETH {
        borrowFromMaturityPool(msg.value, maturityDate, maxAmountAllowed);
    }

    function depositToMaturityPoolEth(
        uint256 maturityDate,
        uint256 minAmountRequired
    ) external payable usingETH {
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

    function repayToMaturityPoolEth(address borrower, uint256 maturityDate)
        external
        payable
        usingETH
    {
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
