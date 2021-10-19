===============
Technical notes
===============

How borrowing works
===================

Assumptions
-----------
- The user has marked one or more assets as collateral


.. uml::

    actor user
    participant Exafin

    user -> Exafin: canIHaveMoney(please)
    user <-- Exafin: yes
