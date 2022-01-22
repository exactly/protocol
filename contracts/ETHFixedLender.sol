// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

// solhint-disable no-empty-blocks
// solhint-disable no-unused-vars

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "./FixedLender.sol";
import "./external/WETH9.sol";
import "./interfaces/IETHFixedLender.sol";

contract ETHFixedLender is FixedLender, IETHFixedLender {
    bool private wrapOnOurSide;
    WETH9 private weth;

    modifier usingETH() {
        wrapOnOurSide = true;
        _;
        wrapOnOurSide = false;
    }

    constructor(
        address payable _tokenAddress,
        string memory _underlyingTokenName,
        address _eTokenAddress,
        address _auditorAddress,
        address _interestRateModelAddress
    )
        FixedLender(
            _tokenAddress,
            _underlyingTokenName,
            _eTokenAddress,
            _auditorAddress,
            _interestRateModelAddress
        )
    {
        // just to be explicit uwu I know it is zero/falsy by default
        wrapOnOurSide = false;
        weth = WETH9(_tokenAddress);
    }

    function borrowFromMaturityPoolEth(
        uint256 maturityDate,
        uint256 maxAmountAllowed
    ) external payable override {}

    function depositToMaturityPoolEth(
        uint256 maturityDate,
        uint256 minAmountRequired
    ) external payable override usingETH {
        depositToMaturityPool(msg.value, maturityDate, minAmountRequired);
    }

    function depositToSmartPoolEth() external payable override usingETH {
        depositToSmartPool(msg.value);
    }

    function withdrawFromSmartPoolEth(uint256 amount) external override {}

    function withdrawFromMaturityPoolEth(
        address payable redeemer,
        uint256 redeemAmount,
        uint256 maturityDate
    ) external override {}

    function repayToMaturityPoolEth(address borrower, uint256 maturityDate)
        external
        payable
        override
    {}

    function doTransferIn(address from, uint256 amount)
        internal
        override
        returns (uint256)
    {
        if (wrapOnOurSide) {
            // giving it some tought, we kind of can trust WETH9 to mint
            // exactly the requested amount. But I'll leave this here for now
            uint256 balanceBefore = trustedUnderlying.balanceOf(address(this));
            weth.deposit{value: msg.value}();
            uint256 balanceAfter = trustedUnderlying.balanceOf(address(this));

            return balanceAfter - balanceBefore;
        } else {
            return super.doTransferIn(from, amount);
        }
    }

    function doTransferOut(address to, uint256 amount) internal override {}
}
