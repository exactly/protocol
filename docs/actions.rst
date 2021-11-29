=======
Actions
=======

Borrowing
=========

Previous steps
--------------
- The user deposited assets in one or more maturity pools
- The user has marked one or more of those assets as collateral

In this case, the user is trying to borrow DAI from the appropiate FixedLender contract, EXADAI


.. uml::

    actor user
    participant EXADAI
    participant InterestRateModel
    participant Auditor
    participant DAI

    user -> EXADAI: borrow(100, poolId)
    EXADAI -> EXADAI: pools(poolId)
    EXADAI <-- EXADAI: pool
    EXADAI -> Auditor: beforeBorrowMP(EXADAI.address, user.address, 100, poolId)
    EXADAI -> InterestRateModel: getRateToBorrow(100, poolId, pool, pool)
    note right: the last parameter should be the pot
    EXADAI <-- InterestRateModel: 10
    note right: the requested amount is sent to the user, but\nin EXADAI's state, the borrowed amount is\nset to amount +commission = 110
    EXADAI -> DAI: transferFrom(EXADAI.address, user.address,100)

.. warning:: The user currently has no way of rejecting the tx if the commisionRate is too high for their liking, this would 100% be a critical audit issue

notes:

- the amounts are in human-readable form
- the maturityDate is a valid poolID
- commissionRate is assumed to be 10%
- poolId is the unix epoch at which a particular maturity pool matures, such as 1634644290

Now, let's see the more complex call:

``Auditor.borrowAllowed``
^^^^^^^^^^^^^^^^^^^^^^^^^

.. note:: In my nitpicky opinion, ``borrowAllowed`` sounds like a function that returns a boolean value, and this reverts if it's not allowed, so it's more like a ``checkValidBorrow``, perhaps?

.. uml::

    participant FixedLender
    participant Auditor
    participant Oracle

    FixedLender -> Auditor: beforeBorrowMP(FixedLender.address, user.address, amount, poolId)

    loop every enabled FixedLender
    Auditor -> FixedLender: getAccountSnapshot(user.address, poolId)
    Auditor <-- FixedLender: balance, borrowBalance
    Auditor -> FixedLender: underlyingTokenName()
    Auditor <-- FixedLender: name
    Auditor -> Oracle: price(name)
    Auditor <-- Oracle: price
    note across
    debt += price*borrowBalance
    collateral += price*balance
    end note

    alt asset == FixedLender.address (the one we're simulating)
    note across
    debt += price*amount
    end note
    end
    note over Auditor: revert if debt > collateral
    FixedLender <-- Auditor

