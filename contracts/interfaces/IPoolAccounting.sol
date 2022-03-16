// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

error AlreadyInitialized();
error TooMuchSlippage();

interface IPoolAccounting {
    function borrowMP(
        uint256 maturityDate,
        address borrower,
        uint256 amount,
        uint256 maxAmountAllowed,
        uint256 eTokenTotalSupply,
        uint8 maxFuturePools
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        );

    function depositMP(
        uint256 maturityDate,
        address supplier,
        uint256 amount,
        uint256 minAmountRequired
    ) external returns (uint256, uint256);

    function withdrawMP(
        uint256 maturityDate,
        address redeemer,
        uint256 amount,
        uint256 minAmountRequired,
        uint256 eTokenTotalSupply,
        uint8 maxFuturePools
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        );

    function repayMP(
        uint256 maturityDate,
        address borrower,
        uint256 repayAmount,
        uint256 maxAmountAllowed
    )
        external
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        );

    function getAccountBorrows(address who, uint256 maturityDate)
        external
        view
        returns (uint256);

    function getTotalMpBorrows(uint256 maturityDate)
        external
        view
        returns (uint256);

    function smartPoolBorrowed() external view returns (uint256);
}
