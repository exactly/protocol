======================
Contracts' UML diagram
======================

.. uml::

    @startuml

    interface IAuditor {
    }
    interface IFixedLender {
    }
    interface IInterestRateModel {
    }
    interface IEToken {
    }
    interface IERC20 {
    }
    interface IOracle {
    }
    class Auditor {
    }
    class FixedLender {
    }
    class InterestRateModel {
    }
    class EToken {
    }

    Auditor ..|> IAuditor
    EToken ..|> IEToken
    InterestRateModel ..|> IInterestRateModel
    ExactlyOracle ..|> IOracle
    IEToken ..|> IERC20
    FixedLender ..|> IFixedLender
    FixedLender --> Auditor
    FixedLender --> InterestRateModel
    FixedLender --> EToken
    EToken --> FixedLender
    EToken --> Auditor
    Auditor --> ExactlyOracle

    @enduml

    