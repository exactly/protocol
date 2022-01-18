// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./IFixedLender.sol";

interface IETHFixedLender is IFixedLender {
    function borrowFromMaturityPoolEth(
        uint256 maturityDate,
        uint256 maxAmountAllowed
    ) external payable;

    function depositToMaturityPoolEth(
        uint256 maturityDate,
        uint256 minAmountRequired
    ) external payable;

    function depositToSmartPoolEth() external payable;

    function withdrawFromSmartPoolEth(uint256 amount) external;

    function withdrawFromMaturityPoolEth(
        address payable redeemer,
        uint256 redeemAmount,
        uint256 maturityDate
    ) external;

    function repayToMaturityPoolEth(address borrower, uint256 maturityDate)
        external
        payable;
}
