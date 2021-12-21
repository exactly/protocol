========
Timelock
========

Administrative functions
========================

As of today we have a total of **10** ``onlyRole(ADMIN)`` functions. Mostly all of these do change risky parameters of the protocol and it's important to have them backed up by a timelock for the safety of users.

That's why, when finally deploying the Timelock it's important to grant the ADMIN role to the TimelockController address in each impacted contract.

In this way, these are the contracts where we should grant the timelock the ADMIN role and at the same time revoke the same role from the owner:

- **Auditor** -> [Necessary to transfer ownership]
    - ``setOracle(address _priceOracleAddress)``
    - ``setLiquidationIncentive(uint256 _liquidationIncentive)``
    - ``setExaSpeed(address fixedLenderAddress, uint256 exaSpeed)``
    - ``enableMarket(address fixedLender, uint256 collateralFactor, string memory symbol, string memory name, uint8 decimals)``
    - ``setMarketBorrowCaps(address[] calldata fixedLenders, uint256[] calldata newBorrowCaps)``
- **FixedLender** -> [Necessary to transfer ownership]
    - ``setLiquidationFee(uint256 _liquidationFee)``
- **InterestRateModel** -> [Necessary to transfer ownership]
    - ``setParameters(uint256 _mpSlopeRate, uint256 _spSlopeRate, uint256 _spHighURSlopeRate, uint256 _slopeChangeRate, uint256 _baseRate, uint256 _penaltyRate)``
- **ExactlyOracle** -> [Necessary to transfer ownership]
    - ``setAssetSources(string[] calldata symbols, address[] calldata sources)``
- **EToken** -> [**NOT** necessary to transfer ownership] [It has only one admin function and it's going to be called only once in initialization]
    - ``setFixedLender(address fixedLenderAddress)``


