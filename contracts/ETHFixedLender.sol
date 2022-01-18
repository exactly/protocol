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
import "./interfaces/IETHFixedLender.sol";

contract ETHFixedLender is FixedLender, IETHFixedLender {
    constructor(
        address _tokenAddress,
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
    {}

    function borrowFromMaturityPoolEth(
        uint256 maturityDate,
        uint256 maxAmountAllowed
    ) external payable override {}

    function depositToMaturityPoolEth(
        uint256 maturityDate,
        uint256 minAmountRequired
    ) external payable override {}

    function depositToSmartPoolEth() external payable override {}

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
        return 0;
    }

    function doTransferOut(address to, uint256 amount) internal override {}
}
