===========
Validations
===========

MARKET_NOT_LISTED & UnmatchedPoolState
=======================================

There are some common validations that are identical for the different flows we currently have between Auditor's and FixedLender's contract.
Since the same code is shared over these flows, the coverage might not identify if we are missing tests.
In the following list I'll make sure we are testing these errors over the different external and public functions we expose. 

**Auditor**:
    - enterMarkets -> **MARKET_NOT_LISTED**
    - exitMarket -> **MARKET_NOT_LISTED**
    - setOracle -> NONE
    - setLiquidationIncentive -> NONE
    - enableMarket -> NONE
    - setMarketBorrowCaps -> **MARKET_NOT_LISTED**
    - validateBorrowMP -> NONE
    - liquidateAllowed -> **MARKET_NOT_LISTED** for both fixedLender addresses sent as parameters
    - seizeAllowed -> **MARKET_NOT_LISTED** for both fixedLender addresses sent as parameters
    - getMarketData -> NONE
    - getAccountLiquidity -> NONE
    - liquidateCalculateSeizeAmount -> NONE (view function, does not update)
    - requirePoolState -> function that is being used to validate
    - getFuturePools -> NONE
    - getMarketAddresses -> NONE
    - validateAccountShortfall -> NONE (view function, does not update)
    - validateMarketListed -> function that is being used to validate

**FixedLender**:
    - setProtocolSpreadFee -> NONE
    - setProtocolLiquidationFee -> NONE
    - setMpDepositDistributionWeighter -> NONE
    - pause -> NONE
    - unpause -> NONE
    - liquidate -> NONE
    - seize -> NONE
    - withdrawFromMaturityPool -> **MARKET_NOT_LISTED** & **TSUtils.State.MATURED**
    - withdrawFromTreasury -> NONE
    - withdrawFromSmartPool -> **MARKET_NOT_LISTED**
    - borrowFromMaturityPool -> **MARKET_NOT_LISTED** & **TSUtils.State.VALID**
    - depositToMaturityPool -> **MARKET_NOT_LISTED** & **TSUtils.State.VALID**
    - repayToMaturityPool -> **MARKET_NOT_LISTED** & **TSUtils.State.MATURED**
    - depositToSmartPool -> **MARKET_NOT_LISTED**

**EToken**:
- transfer -> **MARKET_NOT_LISTED**
