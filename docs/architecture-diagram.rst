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
    interface IERC20Metadata {
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

    IAuditor <|-- Auditor
    IEToken <|-- EToken
    IInterestRateModel <|-- InterestRateModel
    IOracle <|-- ExactlyOracle
    IERC20 <|-- IEToken
    IERC20Metadata <|-- IEToken
    IFixedLender <|-- FixedLender
    FixedLender o-- Auditor
    FixedLender o-- InterestRateModel
    FixedLender o-- EToken
    EToken o-- FixedLender
    Auditor o-- ExactlyOracle

    @enduml

    