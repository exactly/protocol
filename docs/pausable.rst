========
Pausable
========

Halt activity in FixedLender's contract
=======================================

It's important to be able to trigger an emergency stop in response to an external threat at any moment.

That's why we can use the already implemented Open Zeppelin's **Pausable** solution. This contract offers a ``whenNotPaused`` function that is added to other important external/public functions as a modifier.

Since it's only relevant to block the logic with which users interact and persist changes, we should add this capability to the following functions located in FixedLenders' contracts:

- ``borrowFromMaturityPool``
- ``depositToMaturityPool``
- ``withdrawFromMaturityPool``
- ``repayToMaturityPool``
- ``liquidate``
- ``withdrawFromSmartPool``
- ``borrowFromMaturityPool``


