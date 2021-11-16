==============
Contracts' API
==============

.. soliditydomain's grammar is outdated 😭 so I had to skip some fields for it to work
.. soliditydomain doesnt support only showing entities which include a docstring, so for now I'll add them manually

.. autosolcontract:: Exafin
    :members: constructor, getRateToSupply, getRateToBorrow, borrow, supply, redeem, repay, seize, repay, _repayLiquidate, _liquidate, _seize

.. autosolcontract:: InterestRateModel
    :members: constructor, getRateToBorrow, getRateToSupply

.. autosolcontract:: Auditor
    :members: enterMarkets, getAccountLiquidity, liquidateCalculateSeizeAmount, liquidateAllowed, seizeAllowed, enableMarket, pauseBorrow, _accountLiquidity

.. autosolcontract:: ExactlyOracle
    :members: constructor, getAssetPrice, setAssetSources, _setAssetsSources

.. autosolinterface:: IChainlinkFeedRegistry
    :members: latestRoundData
