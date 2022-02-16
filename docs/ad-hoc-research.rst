===============
Ad-hoc research
===============

Solidity math libraries
=======================

PRB-math checklist:
-------------------

- can we only deploy the functionality we need and not bother with the rest?
    - IMO it's not worth it to modify the lib since only functions we use will be inlined into the calling contracts (see below)
- how do the tests look like?
    - most of the tests are comparing the output of the smart contracts vs a js implementation. Looks sufficient, but didn't blow me out of the water
    - (red flag) I can't get the tests to fail 
- is it actively maintained? - Yes
- can I find some project that uses it?
    - https://www.npmjs.com/package/@hifi/amm - in beta, didn't find an audit, it's also a fixed rate protocol, and the one for which the library was developed
    - https://www.npmjs.com/package/synths-sdk - it's an sdk, no audit
    - https://www.npmjs.com/package/@paulrberg/contracts - off-the-shelf contracts. No audit
    - https://www.npmjs.com/package/@tracer-protocol/contracts - the audit mentions ABDKMath but not this library.
    - did it have a good audit? -- no, no audit yet
- any notes about the implementation?
    - between the bitwise operation optimizations and the use of inline assembly, it gives strong DOOM codebase vibes
    - due to the functions being internal, they don't end up in the library's bytecode, but instead on the calling contract. This means if we're only going to use 1-2 functions, we wouldn't have to deploy the 10kbytes of the entire library. Using only ``log2``, for example, only adds 537 bytes to the code size
- gas costs
    - the highest-costing test of the ``ln`` function consumes 4029 gas. For reference, writing to storage consumes 20k gas, and a bare multiplication consumes only 5 gas
    - the ``log2`` (used by ``ln``) function iterates without a set bound, we should check it converges fast enough
        - in the tests, it iterates quite a lot, for example ``✔ takes 6.277101735386681e+75 and 1e+18 and returns the correct value (304ms)`` iterates 59 times
        - ultimately we could reduce the desired precision

ABDK-math
---------

- uses fixed 64.64 bit number (only 128 bits, and 64 bits precision)
    - this has a way bigger behind-the-point precision (the 18 decimals (radix 10) that we use right now uses roughly 15 bits behind the point)
- provides also IEEE754 libraries
- tests aren't provided
- it's not actively maintained

Conclusions
-----------

- The PRB-math library will increase the audit's scope, since it wasn't audited independently and has no 'reputation' unlike the ones from OpenZeppelin.
    - The functionality required to do a natural logarithm would add ~100 (intense) SLOC 
- We can add the PRB-math library without greatly increasing code size
- Gas costs are not prohibitive, but we should research a bit more to ensure it can't enable block gas limit attacks
- The healthiest thing to do would be to add the PRB-math library to the project's dependencies and let the compiler inline the functions we actually use
- I (capu) advise against using ABDK-math for the reasons described above.
- TL;DR if computing logarithms is a requirement, it's sensible to include PRB-math, after taking the cautions described above
- As defined in the meeting with Francisco on 17/12/2021, it's not necessary to compute logarithms and instead we will go with a fixed amount of riemann sums

contract sizes for PRB-Math
---------------------------

.. code:: 

    PRBMathSD59x18Mock
    18491/2 - 4
    9241
    PRBMathSD59x18TypedMock
    21773/2 - 4
    10882
    PRBMathUD60x18Mock
    16335/2 - 4
    8163
    PRBMathUD60x18TypedMock
    19179/2 - 4
    9585
    PRBMathUD60x18Mock -- with only doLog2
    1083/2 - 4
    537

Representing supply/borrow positions via a standard token
=========================================================

Rationale
---------
We want a standard way to represent positions in order for them to show up in user's wallets

notes erc721
------------
The metadata extension is optional, has fields:

- name (for the collection)
- symbol (for the collection)
- tokenURI, takes the tokenid and returns a URI for it. This can be mutable. it can point to a 'ERC721 Metadata JSON Schema', with keys:
    - name (for the item)- string
    - description (for the item)- string
    - image - URI pointing to an image with some restrictions (size, aspect ratio and having a image/* mime type )

The enumeration extension is also optional, adds:

- totalsupply
- tokenByIndex(index) - gets a token at an index, meaning they can be ordered. sort order not specified in the standard
- tokenOfOwnerByIndex(owner, index) - index in the collection of tokens of a particular user

this is a total order, so it's not really useful for the purposes of creating an orderbook sorted by maturity and size

    Every NFT is identified by a unique `uint256` ID inside the ERC-721 smart contract. This identifying number SHALL NOT change for the life of the contract. 

This means we cant make part of the id anything that is subject to change, such as the owner or perhaps the amount

    Also note that a NFTs MAY become invalid (be destroyed). 

This means burning and then minting an nft in the process of transferring is, in theory, valid.

Read-only nft registries are supported in the standard, so making them non-transferrable shouldn't break anything

In order to support erc721, a contract must also support erc165, so if it is ever broken in the UI, then not having the correct erc165 identifiers set might be to blame

notes eip-1155
--------------
- it is possible for an implementation to return a valid URI string even if the token does not exist.
- has a more gas-efficient way of setting the uris
- the uri(id) method takes an id, which is only the first parameter, what I've previously called an index

    The top 128 bits of the uint256 `_id` parameter in any ERC-1155 function MAY represent the base token ID, while the bottom 128 bits MAY represent the index of the non-fungible to make it unique.

we might just be able to use all of this standard's features to create a token that actually represents debt/collateral positions in a way that can potentially be read by other frontends

draft (we could probably move the boundaries so everything fits, since the fixedLender address takes up 20 bytes and we could do with less bytes for the maturity):

================= ===============================   ================================
0                 1-127                             128-255
================= ===============================   ================================
0                 0000000000000000000000000000000   00000000000000000000000000000000
debt/collateral   fixedLender id                         maturity
================= ===============================   ================================

- the amount represents the actual amount supplied/owed
- ...the owner is the owner
- when transferring the pseudonft the id wouldn't change, so that's cool

metamask docs notes
-------------------
- there's a method ``wallet_watchAsset`` on the web3 provider spec (EIP-747), it only works with erc20s
    - the sources (`controllers repo <https://github.com/MetaMask/controllers/blob/main/src/assets/TokensController.ts>`_ ``src/assets/TokensController.ts:405``) only handle adding ERC20s
    - the `support page <https://metamask.zendesk.com/hc/en-us/articles/360058961911-How-do-I-send-receive-or-cash-out-an-NFT->`_ is consistent with^, and also mentions ERC-721 is supported on mobile and on it's way to the extension
    - the docs mention any ERC contract standard can be supported, but doesn't define a minimum set to support

However, when adding an ERC-20 in metamask, it'll succeed with the address of an ERC-721Enumerable, since the only check metamask does is to call the ``balanceOf(address)`` method, which is the same as in an ERC-20. This'd show the amount of positions minted for the user.

TODO

- describe the different alternatives' composability issues
- make a point agains implementing anything

Conclusions
-----------
- With ERC1155 we could implement a cool, standard-compliant and idiomatic way to represent positions, however there's AFAIK no composability benefit for this at this time (ie, there are no places where these erc1155 would be accepted as collateral or a marketplace for them to be sold)
- With ERC721 we could implement something similar but in a more hacky way, and probably less gas efficient.
- Unless we sponsor the development of ERC721/ERC1155 support in metamask, it'll probably not be worth it to implement any of the solutions, since they wouldn't provide the benefit of showing up in the user's wallet
- Regarding composability, there's no silver bullet, since:
    - ERC1155: is not widely adopted
    - ERC20: would have complex rules behind it preventing transfers (red flag for integrations), and would make fungible things that aren't (eg: a supply with maturity date in 6 months and a supply to the smart pool)
    - ERC721: would make non-fungible things that are indeed fungible, such as two supplies to the same maturity.

We chose to not implement any of these alternatives.

Correctly account exa rewards for sender & recipient when etokens are transferred 
=================================================================================

So we have two possible solutions for calling Auditor from eTokens' transfers and updating users' Exa rewards index.
See contracts’ UML diagram to follow up.

1. EToken has Auditor address as state variable and directly calls beforeTransferSP() function.
    - **Pros**: less gas impact for eTokens' transfers.
    - **Cons**: we couple EToken's contract with Auditor's contract. We make EToken contract more extense, having to initialize Auditor's address in constructor, maybe also adding a onlyRole(ADMIN) setter for that Auditor.
2. Since EToken already has the FixedLender's address, it calls a FixedLender's function and that function finally calls beforeTransferSP() from Auditor contract.
    - **Pros**: cleaner design solution, we do not have to add aditional logic to EToken's contract.
    - **Cons**: more gas impact on transfer, we also increase FixedLender's bytecode.

We ended up going for the first one.

Using OZ's TimelockController contract as owner of Exactly's contracts
======================================================================

The idea of using a timelock is to add a delay of administrative actions and it's generally considered a strong indicator that a project is legitimate and demonstrates commitment by the team.
We have two possible approaches to implement this mechanism:

- [] Using a custom-simple made Timelock solution. This requires more testing and it could require more gas costs for normal transactions if logic is coupled to common function calls.
- [x] Using OZ's Compound-based TimelockController solution. Does not require more testing and since it's a separated contract and module, no interaction is needed from common function calls. Only disadvantage involves contract's bytecode syze when deploying once (gas).

We also have two different strategies when implementing ownership in contracts:

- [] Using OZ's Ownable. There’s an account that is the owner of a contract and can do administrative tasks on it.
- [x] Using OZ's AccessControl. While the simplicity of ownership can be useful for simple systems or quick prototyping, different levels of authorization are often needed.

This would be our case when having pausable functions and modifiers. Our idea then is to implement a timelock for contracts' setters but to have another role for being able to pause actions (borrows, deposits, withdrawals, etc) at any moment in case of emergency.

Smart Pool deposits as collateral to borrow from maturities
===========================================================

As decided with the team we will no longer allow deposits to maturities to be 'entered' as collateral for borrowing. Instead, users will now be able to leave their **smart pool deposits** as their guarantee.
This feature brings two major changes to the **collateral** flow:

1. Users will now 'enter a market' without having to send a specific maturity date as parameter, this change makes the logic pretty similar to Compound and Aave that have a single deposit/collateral vault per asset.

2. Once money is left as collateral, users can now borrow different assets from different maturities. In order to consistently calculate users' liquidity (``accountLiquidity()``) when he interacts with the protocol, the ``fixedLender`` now has to iterate over the different maturities to know how much the user owes.
    - But why do we need to iterate over maturities to know how much he owes if we can read its value in mapping ``totalMpDepositsUser``? Well, in fact that's not accurate enough, since we have the penalty system that dynamically increments his borrowed amount from day to day if the mp is matured.
    - That's mainly the reason why a new contract state variable was added to the ``FixedLender`` : ``mapping(address => uint256[]) public userMpBorrowed;`` We ``push`` a maturity date to the array when the user asks for a loan and ``pop`` a maturity from the array when he repays his whole debt.
    - Disclaimer: [] I'm opened to new or better approaches ^^.

Another turning point IMO is **liquidations**. Users can now have multiple borrows in different maturities with a single collateral amount in a specific smart pool. *Notice* that this is different from Compound or Aave that have two unique vaults. 
One for lending one for borrowing, despite different assets.

With this being said, users can ask for many small loans of a same asset (different maturities) or many small loans of different assets/maturities. If their position becomes undercollateralized, 
liquidators will want to liquidate as much as possible and as soon as possible, in order to compete with other liquidators and keep the profit while helping the protocol's solvency. So we have two strategies to achieve this:

1. Liquidators know how much the user owes and how much can be liquidated, so they send the amount and the contract starts iterating over maturities to repay the debt until the max amount is covered.

2. Liquidators choose a maturity to repay, they can send one tx at a time. If the user still has shortfall, then they'll have to send another one an point to another maturity.

As discussed with Lucas, will go for the second one. Bear in mind that it might not be so useful/efficient from a liquidator's point of view. I'm also opened here for other approaches.

Accepting bare ETH
==================
So far we have two ideas for accepting eth deposits:

Wrapper contract
----------------

.. uml::
    :caption: depositMP

    actor user
    participant ETHFixedLender
    participant FixedLender
    participant WETH

    user -> ETHFixedLender: depositMP(poolId, {value: 100})
    ETHFixedLender -> WETH: wrap({value: 100})
    ETHFixedLender <-- WETH
    ETHFixedLender -> FixedLender: depositMP(user, poolId, 100)
    ETHFixedLender <-- FixedLender
    ETHFixedLender -> ETHFixedLender: ...registers the user has a deposit
    user <--ETHFixedLender

.. uml::
    :caption: withdrawMP

    actor user
    participant ETHFixedLender
    participant FixedLender
    participant WETH

    user -> ETHFixedLender: withdrawMP(poolId, 100, v, r, s)
    ETHFixedLender -> FixedLender: withdrawMP(user, poolId, 100, v, r, s)
    ETHFixedLender <-- FixedLender
    ETHFixedLender -> WETH: unwrap(100)
    ETHFixedLender <-- WETH
    ETHFixedLender -> user: .send("", {value: 100})
    note right: this is where a reentrancy attack could happen
    ETHFixedLender <-- user
    user <--ETHFixedLender

.. uml::
    :caption: depositSP

    actor user
    participant ETHFixedLender
    participant FixedLender
    participant WETH
    participant EWETH

    user -> ETHFixedLender: depositSP({value: 100})
    ETHFixedLender -> WETH: wrap({value: 100})
    ETHFixedLender <-- WETH
    ETHFixedLender -> FixedLender: depositSP(user, 100)
    FixedLender -> EWETH: mint(user, 100)
    FixedLender <-- EWETH
    ETHFixedLender <-- FixedLender
    user <--ETHFixedLender

Another possible alternative is to leave the tokens under ETHFixedLender's
custody but set an allowance for the user so they can withdrawn them if needed,
and don't have to set an allowance to the ETHFixedLender when they want to
withdraw from the smart pool

.. uml::
    :caption: withdrawSP

    actor user
    participant ETHFixedLender
    participant FixedLender
    participant WETH
    participant EWETH

    user -> ETHFixedLender: withdrawSP(100, v,r,s)
    ETHFixedLender -> EWETH: transferFrom(user, ETHFixedLender, 100)
    ETHFixedLender <-- EWETH:
    ETHFixedLender -> FixedLender: withdrawSP(user, 100, v, r, s)
    FixedLender -> EWETH: burn(ETHFixedLender, 100)
    FixedLender <-- EWETH
    ETHFixedLender <-- FixedLender
    ETHFixedLender -> user: .send("", {value: 100})
    note right: this is where a reentrancy attack could happen
    ETHFixedLender <-- user
    user <--ETHFixedLender

Notes
^^^^^

- [ ] we might have to do minor modifications to the deposit/withdraw methods in order to be able to easily track the amount that was actually deposited/withdrawn
- [ ] We'll have to look into reentrancy issues on withdrawals, since we'll call the user back with an eth transfer (which might be a contract)
- [ ] It's necessary to add a ``from`` argument to the ``FixedLender`` and have it track position ownership instead of having a custodial ``ETHFixedLender``, because otherwise all of the positions created via the ``ETHFixedLender`` would share a liquidity computation.
- [ ] when handling withdrawals, we should decide if we want the ``FixedLender`` to transfer the tokens to the caller (``ETHFixedLender`` in this case) or the user.
- [ ] verifying the signatures (``v,r,s`` values) is not trivial, the correct thing to do would be to do a ERC-712 signature verification. However, `OZ's implementation <https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/cryptography/draft-EIP712.sol>`_ is still in draft status. We should decide if we want to use it regardless or import some other implementation
- [ ] with a working ERC-712 implementation, doing the signature check shouldn't be too hard, but review from someone who actually knows their crypto would be of great value.

Extension by inheritance to the WETH FixedLender contract
---------------------------------------------------------

The idea would be to add some methods to the default FixedLender via inheritance in order to receive ETH directly.

.. uml::

    @startuml

    interface IFixedLender {
        + depositToSmartPool()
        + withdrawFromSmartPool()
        + depositToMaturityPool()
        + withdrawFromMaturityPool()
        + repayToMaturityPool()
    }
    class IERC20 {
    }
    class WETH {
    }
    class FixedLender {
        # doTransferIn(from, amount): actualReceived
        # doTransferOut(to, amount)
    }
    class ETHFixedLender {
        # doTransferIn(from, amount): actualReceived
        # doTransferOut(to, amount)
    }

    FixedLender ..|> IFixedLender
    FixedLender o-- IERC20 : has underlying
    ETHFixedLender o-- WETH : uses for wrapping
    ETHFixedLender --|> FixedLender
    WETH --|> IERC20

    @enduml

A core difference in the implementation would be that we'd have to add hook-style functions to the ``FixedLender`` to get money in and out of the system, which would be overriden in the ``ETHFixedLender``

hooks for transfer in
^^^^^^^^^^^^^^^^^^^^^
- [ ] depositToMaturityPool , FixedLender.sol:262
- [ ] depositToSmartPool, FixedLender.sol:386
- [ ] _repay, FixedLender.sol:511

that's basically all calls to ``doTransferIn``, we could just make that function virtual

hooks for transfer out
^^^^^^^^^^^^^^^^^^^^^^
- [ ] borrowFromMaturityPool contracts/FixedLender.sol:236
- [ ] withdrawFromMaturityPool contracts/FixedLender.sol:310
- [ ] withdrawFromSmartPool contracts/FixedLender.sol:412
- [ ] _seize contracts/FixedLender.sol:668

Notes
^^^^^
- [ ] the ``liquidate`` method doesn't have its eth-receiving couterpart, given that any user technical enough to do liquidations can probably wrap ETH on their own
- [ ] it's not necessary to override ``balanceOf`` usages since the only context in which it's called on the underlying token is inside the ``doTransferIn`` method, and the global/by user accounting are updated with the return value of the latter function

How accepting ETH works in Compound
-----------------------------------

.. uml::

    class CToken{
        doTransferIn(...) abstract
        doTransferOut(...) abstract
    }
    class CERC20{}
    class CEther{
        mint() external payable 
        redeem(redeemTokens) external 
        redeemUnderlying(redeemAmount) external 
        borrow(uint borrowAmount) external 
        repayBorrow() external payable 
        repayBorrowBehalf(borrower) external payable 
        liquidateBorrow(borrower, cTokenCollateral) external payable 
    }
    interface CErc20Interface{
        mint(mintAmount) external 
        redeem(redeemTokens) external 
        redeemUnderlying(redeemAmount) external 
        borrow(borrowAmount) external 
        repayBorrow(repayAmount) external 
        repayBorrowBehalf(borrower, repayAmount) external 
        liquidateBorrow(borrower, repayAmount, cTokenCollateral) external 
        sweepToken(token) external
    }

    CERC20 --|> CToken 
    CERC20 ..|> CErc20Interface
    CEther --|> CToken

note from the above, ``CEther`` and ``CErc20Interface`` have similar but not identical ABIs, so ``CEther`` doesn't implement ``CErc20Interface``

Also, the bulk of the functionality is implemented in ``CToken``, similar to how in our current approach most of the functionality is implemented in the ``FixedLender``

The key difference (at a technical level) is, while we implement the ``doTransfer{In,Out}`` in the ``FixedLender`` and override them in the ``ETHFixedLender``, in Compound's case the functions are abstract in the ``CToken`` and the derived classes implement them separately.

A user-facing consecuence of this is that it's not possible to accept both ``ETH`` and ``WETH`` in the same contract with Compound, something that we're able to do

Pros
^^^^
- In the case of ``CEther``, it's a bit more gas efficient, since no wrapping or ERC20 transfers are done
- Having the transfer hooks as abstract in a base contract and implementing them separately is a bit less confusing than our override-but-sometimes-use-the-default-behaviour approach

Cons
^^^^
- It's not possible to accept ``ETH`` and ``WETH`` in the same contract

Gas savings by using smaller variables in InterestRateModel
===========================================================

The parameters of the InterestRateModel are all values which can be more or less be guaranteed to be less than 10, and they all have 18 decimals precision. so, the required variable length would be ...int64 for any of them:

.. code:: 

    in base 10:
    10000000000000000000
    in hexadecimal:
    dec2hex 10000000000000000000
    8ac7230489e80000
    length: 16, meaning 8 bytes, so a int64 could suffice
    max value representable by a
    int64:
    2^63 - 1 (might be off by literally 1, idc)
    9223372036854775807/10^18
    9.22337203685477580700
    uint64:
    2^64 - 1
    18446744073709551615/10^18
    18.44674407370955161500

However, given that we have to do divisions, and for that multiply the numerator by 10^18, in some cases we have to use ``{u,}int128`` s (see the patch for details)

Gas costs after this patch (running only 8_interest_rate_model.ts):

==================== ======================== ======== ======== ====
  Contract            Method                   Min      Max      Avg
==================== ======================== ======== ======== ====
  FixedLender         borrowFromMaturityPool   438328   538128   512058

  FixedLender         depositToMaturityPool    -        -        255883

  FixedLender         depositToSmartPool       223423   223435   223432

  InterestRateModel   setParameters            34772    35084    35041
==================== ======================== ======== ======== ====

Gas costs before:

==================== ======================== ======== ======== ====
  Contract            Method                   Min      Max      Avg
==================== ======================== ======== ======== ====
  FixedLender         borrowFromMaturityPool   441942   541742   515672

  FixedLender         depositToMaturityPool    -        -        255883

  FixedLender         depositToSmartPool       223423   223435   223432

  InterestRateModel   setParameters            40247    48659    41729
==================== ======================== ======== ======== ====


this yields 3614 average gas savings for the ``borrowFromMaturityPool`` function, which is pretty low considering the level of anxiety doing that many casts and being that short on bits gives me, so my recommendation is to not implement this savings (or at least not in this stage of the project, perhaps that kind of optimization doesn't feel so so premature in the future)

gas savings in ``setPrameters`` are more significative, but they're also much less relevant since it's a governance action that'll be called way less often.

the patch:

.. TODO look into moving this to its own file if this file grows much larger

.. code::

    diff --git a/contracts/InterestRateModel.sol b/contracts/InterestRateModel.sol
    index 9afe35c..2f4b852 100644
    --- a/contracts/InterestRateModel.sol
    +++ b/contracts/InterestRateModel.sol
    @@ -10,19 +10,20 @@ import "@openzeppelin/contracts/utils/math/Math.sol";
     contract InterestRateModel is IInterestRateModel, AccessControl {
         using PoolLib for PoolLib.MaturityPool;
         using DecimalMath for uint256;
    +    using DecimalMath for uint64;
         uint256 private constant YEAR = 365 days;
     
         // Parameters to the system, expressed with 1e18 decimals
    -    uint256 public curveParameterA;
    -    int256 public curveParameterB;
    -    uint256 public maxUtilizationRate;
    -    uint256 public override penaltyRate;
    +    uint64 public curveParameterA;
    +    int64 public curveParameterB;
    +    uint64 public maxUtilizationRate;
    +    uint64 public override penaltyRate;
     
         constructor(
    -        uint256 _curveParameterA,
    -        int256 _curveParameterB,
    -        uint256 _maxUtilizationRate,
    -        uint256 _penaltyRate
    +        uint64 _curveParameterA,
    +        int64 _curveParameterB,
    +        uint64 _maxUtilizationRate,
    +        uint64 _penaltyRate
         ) {
             _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
             setParameters(
    @@ -41,10 +42,10 @@ contract InterestRateModel is IInterestRateModel, AccessControl {
          * @param _penaltyRate daily rate charged on late repays. 18 decimals
          */
         function setParameters(
    -        uint256 _curveParameterA,
    -        int256 _curveParameterB,
    -        uint256 _maxUtilizationRate,
    -        uint256 _penaltyRate
    +        uint64 _curveParameterA,
    +        int64 _curveParameterB,
    +        uint64 _maxUtilizationRate,
    +        uint64 _penaltyRate
         ) public onlyRole(DEFAULT_ADMIN_ROLE) {
             curveParameterA = _curveParameterA;
             curveParameterB = _curveParameterB;
    @@ -82,18 +83,21 @@ contract InterestRateModel is IInterestRateModel, AccessControl {
             if (supplied == 0) {
                 revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
             }
    -        uint256 utilizationRate = borrowedMP.div_(supplied);
    +        // U is always < 2 < type(uint64).max ~= 18 and overflows are checked
    +        // by solidity so it can't go back to a valid value
    +        uint64 utilizationRate = uint64(borrowedMP.div_(supplied));
             if (
                 utilizationRate >= maxUtilizationRate ||
                 borrowedMP > suppliedMP + borrowableFromSP
             ) {
                 revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
             }
    -        int256 rate = int256(
    -            curveParameterA.div_(maxUtilizationRate - utilizationRate)
    +
    +        int256 rate = int64(
    +            curveParameterA.div_u64(maxUtilizationRate - utilizationRate)
             ) + curveParameterB;
             // this curve _could_ go below zero if the parameters are set wrong.
             assert(rate > 0);
    -        return (uint256(rate) * (maturityDate - currentDate)) / YEAR;
    +        return (uint256(int256(rate)) * (maturityDate - currentDate)) / YEAR;
         }
     }
    diff --git a/contracts/external/MockedInterestRateModel.sol b/contracts/external/MockedInterestRateModel.sol
    index e274504..b920580 100644
    --- a/contracts/external/MockedInterestRateModel.sol
    +++ b/contracts/external/MockedInterestRateModel.sol
    @@ -9,7 +9,7 @@ import "@openzeppelin/contracts/utils/math/Math.sol";
     
     contract MockedInterestRateModel is IInterestRateModel {
         uint256 public borrowRate;
    -    uint256 public override penaltyRate;
    +    uint64 public override penaltyRate;
     
         function getRateToBorrow(
             uint256 maturityDate,
    @@ -25,7 +25,7 @@ contract MockedInterestRateModel is IInterestRateModel {
             borrowRate = newRate;
         }
     
    -    function setPenaltyRate(uint256 newRate) public {
    +    function setPenaltyRate(uint64 newRate) public {
             penaltyRate = newRate;
         }
     }
    diff --git a/contracts/interfaces/IInterestRateModel.sol b/contracts/interfaces/IInterestRateModel.sol
    index 51f3c7d..f72597c 100644
    --- a/contracts/interfaces/IInterestRateModel.sol
    +++ b/contracts/interfaces/IInterestRateModel.sol
    @@ -12,5 +12,5 @@ interface IInterestRateModel {
             uint256 borrowableFromSP
         ) external view returns (uint256);
     
    -    function penaltyRate() external view returns (uint256);
    +    function penaltyRate() external view returns (uint64);
     }
    diff --git a/contracts/utils/DecimalMath.sol b/contracts/utils/DecimalMath.sol
    index 2691df1..9dc3e97 100644
    --- a/contracts/utils/DecimalMath.sol
    +++ b/contracts/utils/DecimalMath.sol
    @@ -24,6 +24,10 @@ library DecimalMath {
             return (a * NUMBER_SCALE) / b;
         }
     
    +    function div_u64(uint64 a, uint64 b) internal pure returns (uint64) {
    +        return uint64((uint128(a) * 1 ether) / b);
    +    }
    +
         function add_(Double memory a, Double memory b)
             internal
             pure
