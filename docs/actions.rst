=======
Actions
=======

Borrowing
=========

Previous steps
--------------
- The user deposited assets in one or more maturity pools
- The user has marked one or more of those assets as collateral

In this case, the user is trying to borrow DAI from the appropiate Exafin contract, EXADAI


.. uml::

    actor user
    participant EXADAI
    participant InterestRateModel
    participant Auditor
    participant DAI

    user -> EXADAI: borrow(100, 1634644290)
    EXADAI -> EXADAI: pools(1634644290)
    EXADAI <-- EXADAI: pool
    EXADAI -> Auditor: borrowAllowed(EXADAI.address, user.address, 100, 1634644290)
    EXADAI -> InterestRateModel: getRateToBorrow(100, 1634644290, pool, pool)
    note right: the last parameter should be the pot
    EXADAI <-- InterestRateModel: 10
    note right: the requested amount is sent to the user, but\nin EXADAI's state, the borrowed amount is\nset to amount +commission = 110
    EXADAI -> DAI: transferFrom(EXADAI.address, user.address,100)

.. warning:: The user currently has no way of rejecting the tx if the commisionRate is too high for their liking, this would 100% be a critical audit issue

notes:

- the amounts are in human-readable form
- the maturityDate is a valid poolID
- commissionRate is assumed to be 10%
