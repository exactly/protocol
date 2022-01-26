===================
Interest rate model
===================

Bare theory
===========

From the *Exactly Finance: A Model for the Development of a Fixed Income Market on the Etherum network (v.0.1)* document:

    The model for interest rates as a function of the utilization ratio is described
    with a single continuous and differentiable function

.. math:: 

    R(U)=\frac{A}{(U_{max}-U)}+B

..

    This function diverges asymptotically when U → U max and it acts as a
    natural barrier to the credit demand as the level of utilization depletes the
    protocol liquidity capabilities.

    :math:`A` and :math:`B` are determined from calibration against relevant market data.

.. math::

    R(U=0) = R_{0} = \frac{A}{U_{max}} + B

    R(U_{b}) = R_{b} = \frac{A}{(U_{max}-U_{b})}+B

..

    where :math:`U_{b}` represents the utilization level at the boundary of normal and leveraged interest rate regions.

.. math::

    A = \frac{U_{max}(U_{max}-U_{b})}{U_{b}}(R_{b}-R_{0})

    B = \frac{U_{max}}{U_{b}}R0+(1-\frac{U_{max}}{U_{b}})R_{b}

Aditionally,

- :math:`U` stands for the *utilization rate*, defined as

.. math::

    U = \frac{BM_{i}}{max(\frac{SS}{nMaturities},SM_{i})}

..

    - :math:`BM_{i}` total borrows at maturity :math:`i`
    - :math:`nMaturities` total number of maturities in a given ``Fixedlender``
    - :math:`SS` total supplied to the smart pool
    - :math:`SM_{i}` total supplied to maturity :math:`i`

- :math:`R_{0}` stands for the interest rate when the utilization rate (:math:`U`) is zero, meaning the rate that'll be charged to the first borrower of a maturity
- :math:`U_{b}` is the *boundary* utilization rate, at which the curve gets steeper, with the idea of having the interest rate naturally tend to :math:`R(U_{b})`. Anything *below* :math:`U_{b}` is considered *normal* and anything *above* is considered *leveraged*.
- :math:`R_{b}` is the aforementioned :math:`R(U_{b})`, the interest rate when :math:`U=U_{b}`

Examples
========

TODO

Notes
=====

- A :math:`\beta_{M}` factor could be added to the computation of :math:`U`, multiplying the maturity pool deposits, if we intend to not offer all of the MP funds for borrowing

Unanswered questions
====================
Why is :math:`U` defined as:

.. math::

    U = \frac{BM_{i}}{max(\frac{SS}{nMaturities},SM_{i})}

and not as:

.. math::

    U = \frac{BM_{i}}{\frac{SS}{nMaturities}+SM_{i}}

if both SP and MP funds can be lent out simultanously?

Implementation checks
=====================

TODO

.. this is a placeholder for when we implement&check

.. plot::

    import matplotlib.pyplot as plt
    import numpy as np

    x=np.linspace(0,1)
    y= x ** 2
    plt.plot(x, y)
    plt.show()

Security considerations
=======================
- We should set, either hardcoded or or at deploy time, the max/min values between which the :math:`A` and :math:`B` parameters will be valid to set in the normal contract's lifecycle.
