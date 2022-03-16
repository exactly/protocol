==============
Contracts' API
==============

.. soliditydomain's grammar is outdated 😭 so I had to skip some fields for it to work
.. soliditydomain doesnt support only showing entities which include a docstring, so for now I'll add them manually

.. autosolcontract:: FixedLender
    :members: constructor, borrowFromMaturityPool, depositToMaturityPool, withdrawFromMaturityPool, repayToMaturityPool, liquidate, seize, depositToSmartPool, withdrawFromSmartPool, getUserMaturitiesOwed, setLiquidationFee, pause, unpause, getAccountSnapshot, getTotalMpBorrows, getAuditor, _repayLiquidate, _liquidate, _seize

.. autosolcontract:: InterestRateModel
    :members: constructor, setParameters, getFeeToBorrow, getRateToSupply

.. autosolcontract:: Auditor
    :members: constructor, enterMarkets, exitMarket, setOracle, setLiquidationIncentive, setExaSpeed, enableMarket, setMarketBorrowCaps, beforeDepositSP, beforeWithdrawSP, beforeDepositMP, beforeBorrowMP, beforeWithdrawMP, beforeRepayMP, liquidateAllowed, seizeAllowed, getMarketData, getAccountLiquidity, liquidateCalculateSeizeAmount, requirePoolState, getFuturePools, getMarketAddresses, claimExa, _requirePoolState, _beforeWithdrawSP

.. autosolcontract:: ExactlyOracle
    :members: constructor, setAssetSources, getAssetPrice, _setAssetsSources, _scaleOraclePriceByDigits

.. autosolinterface:: IChainlinkFeedRegistry
    :members: latestRoundData
