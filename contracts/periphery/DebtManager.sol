// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { AddressUpgradeable as Address } from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import { Market, ERC20, FixedLib, Disagreement } from "../Market.sol";
import { Auditor, IPriceFeed, MarketNotListed } from "../Auditor.sol";

/// @title DebtManager
/// @notice Contract for efficient debt management of accounts interacting with Exactly Protocol.
contract DebtManager is Initializable {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;
  using FixedLib for FixedLib.Position;
  using FixedLib for FixedLib.Pool;
  using Address for address;

  /// @notice Auditor contract that lists the markets that can be leveraged.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;
  /// @notice Permit2 contract to be used to transfer assets from accounts.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPermit2 public immutable permit2;
  /// @notice Balancer's vault contract that is used to take flash loans.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IBalancerVault public immutable balancerVault;
  /// @notice Factory contract to be used to compute the address of the Uniswap V3 pool.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  address public immutable uniswapV3Factory;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_, IPermit2 permit2_, IBalancerVault balancerVault_, address uniswapV3Factory_) {
    auditor = auditor_;
    permit2 = permit2_;
    balancerVault = balancerVault_;
    uniswapV3Factory = uniswapV3Factory_;

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize() external initializer {
    Market[] memory markets = auditor.allMarkets();
    for (uint256 i = 0; i < markets.length; ++i) approve(markets[i]);
  }

  /// @notice Leverages the floating position of `_msgSender` a certain `ratio` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param deposit The amount of assets to deposit.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  function leverage(Market market, uint256 deposit, uint256 ratio) public msgSender {
    transferIn(market, deposit);
    noTransferLeverage(market, deposit, ratio);
  }

  /// @notice Leverages the floating position of `_msgSender` a certain `ratio` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param deposit The amount of assets to deposit.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  /// @param borrowAssets The amount of assets to allow this contract to borrow on behalf of `_msgSender`.
  /// @param marketPermit Arguments for the permit call to `market` on behalf of `_msgSender`.
  /// @param assetPermit Arguments for the permit2 asset call.
  /// Permit `value` should be `borrowAssets`.
  function leverage(
    Market market,
    uint256 deposit,
    uint256 ratio,
    uint256 borrowAssets,
    Permit calldata marketPermit,
    Permit2 calldata assetPermit
  ) external permit(market, borrowAssets, marketPermit) permitTransfer(market.asset(), deposit, assetPermit) msgSender {
    noTransferLeverage(market, deposit, ratio);
  }

  /// @notice Leverages the floating position of `_msgSender` a certain `ratio` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param deposit The amount of assets to deposit.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  /// @param borrowAssets The amount of assets to allow this contract to borrow on behalf of `_msgSender`.
  /// @param marketPermit Arguments for the permit call to `market` on behalf of `_msgSender`.
  /// @param assetPermit Arguments for the permit2 asset call.
  /// Permit `value` should be `borrowAssets`.
  function leverage(
    Market market,
    uint256 deposit,
    uint256 ratio,
    uint256 borrowAssets,
    Permit calldata marketPermit,
    Permit calldata assetPermit
  ) external permit(market, borrowAssets, marketPermit) permit(market.asset(), deposit, assetPermit) {
    leverage(market, deposit, ratio);
  }

  /// @notice Leverages the floating position of `_msgSender` a certain `ratio` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param deposit The amount of assets to deposit.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  /// @param borrowAssets The amount of assets to allow this contract to borrow on behalf of `_msgSender`.
  /// @param marketPermit Arguments for the permit call to `market` on behalf of `_msgSender`.
  /// Permit `value` should be `borrowAssets`.
  function leverage(
    Market market,
    uint256 deposit,
    uint256 ratio,
    uint256 borrowAssets,
    Permit calldata marketPermit
  ) external permit(market, borrowAssets, marketPermit) msgSender {
    market.asset().safeTransferFrom(msg.sender, address(this), deposit);
    noTransferLeverage(market, deposit, ratio);
  }

  /// @notice Leverages the floating position of `_msgSender` a certain `ratio` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param deposit The amount of assets to deposit.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  function noTransferLeverage(Market market, uint256 deposit, uint256 ratio) internal {
    uint256[] memory amounts = new uint256[](1);
    ERC20[] memory tokens = new ERC20[](1);
    tokens[0] = market.asset();
    address sender = _msgSender;

    uint256 loopCount;
    {
      uint256 collateral = market.maxWithdraw(sender);
      uint256 targetDeposit = (collateral + deposit - floatingBorrowAssets(market)).mulWadDown(ratio);
      uint256 amount = targetDeposit - (collateral + deposit);
      loopCount = amount.mulDivUp(1, tokens[0].balanceOf(address(balancerVault)));
      amounts[0] = amount.mulDivUp(1, loopCount);
    }
    bytes[] memory calls = new bytes[](2 * loopCount);
    uint256 callIndex = 0;
    for (uint256 i = 0; i < loopCount; ) {
      calls[callIndex++] = abi.encodeCall(market.deposit, (i == 0 ? amounts[0] + deposit : amounts[0], sender));
      calls[callIndex++] = abi.encodeCall(
        market.borrow,
        (amounts[0], i + 1 == loopCount ? address(balancerVault) : address(this), sender)
      );
      unchecked {
        ++i;
      }
    }

    balancerVault.flashLoan(address(this), tokens, amounts, call(abi.encode(market, calls)));
  }

  /// @notice Deleverages `_msgSender`'s position to a `ratio` via flash loan from Balancer's vault.
  /// @param market The Market to deleverage the position out.
  /// @param ratio The ratio of the borrow that will be repaid, represented with 18 decimals.
  /// @param withdraw The amount of assets that will be withdrawn to `_msgSender`.
  /// @param permitAssets The amount of assets to allow this contract to withdraw on behalf of `_msgSender`.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  /// Permit `value` should be `permitAssets`.
  function deleverage(
    Market market,
    uint256 ratio,
    uint256 withdraw,
    uint256 permitAssets,
    Permit calldata p
  ) external permit(market, permitAssets, p) {
    deleverage(market, ratio, withdraw);
  }

  /// @notice Deleverages `_msgSender`'s position to a `ratio` via flash loan from Balancer's vault.
  /// @param market The Market to deleverage the position out.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  /// @param withdraw The amount of assets that will be withdrawn to `_msgSender`.
  function deleverage(Market market, uint256 ratio, uint256 withdraw) public msgSender {
    RollVars memory r;
    r.amounts = new uint256[](1);
    r.tokens = new ERC20[](1);
    r.tokens[0] = market.asset();
    address sender = _msgSender;

    uint256 collateral = market.maxWithdraw(sender) - withdraw;
    uint256 amount = collateral - (collateral - floatingBorrowAssets(market)).mulWadDown(ratio);

    r.loopCount = amount.mulDivUp(1, r.tokens[0].balanceOf(address(balancerVault)));
    r.amounts[0] = amount.mulDivUp(1, r.loopCount);
    r.calls = new bytes[](2 * r.loopCount + (withdraw == 0 ? 0 : 1));
    uint256 callIndex = 0;
    for (uint256 i = 0; i < r.loopCount; ) {
      r.calls[callIndex++] = abi.encodeCall(market.repay, (r.amounts[0], sender));
      r.calls[callIndex++] = abi.encodeCall(
        market.withdraw,
        (r.amounts[0], i + 1 == r.loopCount ? address(balancerVault) : address(this), sender)
      );
      unchecked {
        ++i;
      }
    }
    if (withdraw != 0) r.calls[callIndex] = abi.encodeCall(market.withdraw, (withdraw, sender, sender));

    balancerVault.flashLoan(address(this), r.tokens, r.amounts, call(abi.encode(market, r.calls)));
  }

  /// @notice Cross-leverages `_msgSender`'s position to a `ratio` via flash swap from Uniswap's pool.
  /// @param marketIn The Market to deposit the leveraged position.
  /// @param marketOut The Market to borrow the leveraged position.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @param deposit The amount of `marketIn` underlying assets to deposit.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this.
  function crossLeverage(
    Market marketIn,
    Market marketOut,
    uint24 fee,
    uint256 deposit,
    uint256 ratio,
    uint160 sqrtPriceLimitX96
  ) external msgSender {
    transferIn(marketIn, deposit);
    noTransferCrossLeverage(marketIn, marketOut, fee, deposit, ratio, sqrtPriceLimitX96);
  }

  /// @notice Cross-leverages `_msgSender`'s position to a `ratio` via flash swap from Uniswap's pool.
  /// @param marketIn The Market to deposit the leveraged position.
  /// @param marketOut The Market to borrow the leveraged position.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @param deposit The amount of `marketIn` underlying assets to deposit.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this.
  /// @param borrowAssets The amount of assets to allow this contract to borrow on behalf of `_msgSender`.
  /// @param marketPermit Arguments for the permit call to `marketOut` on behalf of `_msgSender`.
  /// @param assetPermit Arguments for the permit2 asset call.
  /// Permit `value` should be `borrowAssets`.
  function crossLeverage(
    Market marketIn,
    Market marketOut,
    uint24 fee,
    uint256 deposit,
    uint256 ratio,
    uint160 sqrtPriceLimitX96,
    uint256 borrowAssets,
    Permit calldata marketPermit,
    Permit2 calldata assetPermit
  )
    external
    permit(marketOut, borrowAssets, marketPermit)
    permitTransfer(marketIn.asset(), deposit, assetPermit)
    msgSender
  {
    noTransferCrossLeverage(marketIn, marketOut, fee, deposit, ratio, sqrtPriceLimitX96);
  }

  /// @notice Cross-leverages `_msgSender`'s position to a `ratio` via flash swap from Uniswap's pool.
  /// @param marketIn The Market to deposit the leveraged position.
  /// @param marketOut The Market to borrow the leveraged position.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @param deposit The amount of `marketIn` underlying assets to deposit.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this.
  function noTransferCrossLeverage(
    Market marketIn,
    Market marketOut,
    uint24 fee,
    uint256 deposit,
    uint256 ratio,
    uint160 sqrtPriceLimitX96
  ) internal {
    LeverageVars memory v;
    v.assetIn = address(marketIn.asset());
    v.assetOut = address(marketOut.asset());
    v.sender = _msgSender;

    v.amount =
      (crossedPrincipal(marketIn, marketOut, v.sender, 0) + deposit).mulWadDown(ratio) -
      marketIn.maxWithdraw(v.sender) -
      deposit;

    PoolKey memory poolKey = PoolAddress.getPoolKey(v.assetIn, v.assetOut, fee);
    IUniswapV3Pool(PoolAddress.computeAddress(uniswapV3Factory, poolKey)).swap(
      address(this),
      v.assetOut == poolKey.token0,
      -int256(v.amount),
      sqrtPriceLimitX96,
      abi.encode(
        SwapCallbackData({
          marketIn: marketIn,
          marketOut: marketOut,
          assetIn: v.assetIn,
          assetOut: v.assetOut,
          principal: deposit,
          account: v.sender,
          fee: fee,
          leverage: true
        })
      )
    );
  }

  /// @notice Cross-deleverages `_msgSender`'s position to a `ratio` via flash swap from Uniswap's pool.
  /// @param marketIn The Market to withdraw the leveraged position.
  /// @param marketOut The Market to repay the leveraged position.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @param withdraw The amount of assets that will be withdrawn to `_msgSender`.
  /// @param ratio The number of times that the current principal will end up leveraged, represented with 18 decimals.
  /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this.
  function crossDeleverage(
    Market marketIn,
    Market marketOut,
    uint24 fee,
    uint256 withdraw,
    uint256 ratio,
    uint160 sqrtPriceLimitX96
  ) public msgSender {
    LeverageVars memory v;
    v.assetIn = address(marketIn.asset());
    v.assetOut = address(marketOut.asset());
    v.sender = _msgSender;

    v.amount =
      floatingBorrowAssets(marketOut) -
      (
        ratio > 1e18
          ? previewAssetsOut(
            marketIn,
            marketOut,
            crossedPrincipal(marketIn, marketOut, v.sender, withdraw).mulWadDown(ratio - 1e18)
          )
          : 0
      );

    PoolKey memory poolKey = PoolAddress.getPoolKey(v.assetIn, v.assetOut, fee);
    IUniswapV3Pool(PoolAddress.computeAddress(uniswapV3Factory, poolKey)).swap(
      address(this),
      v.assetIn == poolKey.token0,
      -int256(v.amount),
      sqrtPriceLimitX96,
      abi.encode(
        SwapCallbackData({
          marketIn: marketIn,
          marketOut: marketOut,
          assetIn: v.assetIn,
          assetOut: v.assetOut,
          principal: withdraw,
          account: v.sender,
          fee: fee,
          leverage: false
        })
      )
    );
  }

  /// @notice Cross-deleverages `_msgSender`'s position to a `ratio` via flash swap from Uniswap's pool.
  /// @param marketIn The Market to withdraw the leveraged position.
  /// @param marketOut The Market to repay the leveraged position.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @param withdraw The amount of assets that will be withdrawn to `_msgSender`.
  /// @param ratio The number of times that the current principal will end up leveraged, represented with 18 decimals.
  /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this.
  /// @param permitAssets The amount of assets to allow.
  /// @param p Arguments for the permit call to `marketIn` on behalf of `_msgSender`.
  /// Permit `value` should be `permitAssets`.
  function crossDeleverage(
    Market marketIn,
    Market marketOut,
    uint24 fee,
    uint256 withdraw,
    uint256 ratio,
    uint160 sqrtPriceLimitX96,
    uint256 permitAssets,
    Permit calldata p
  ) external permit(marketIn, permitAssets, p) {
    crossDeleverage(marketIn, marketOut, fee, withdraw, ratio, sqrtPriceLimitX96);
  }

  /// @notice Rolls a percentage of the fixed position of `_msgSender` to another fixed pool.
  /// @param market The Market to roll the position in.
  /// @param repayMaturity The maturity of the fixed pool that the position is being rolled from.
  /// @param borrowMaturity The maturity of the fixed pool that the position is being rolled to.
  /// @param maxRepayAssets Max amount of debt that the account is willing to accept to be repaid.
  /// @param maxBorrowAssets Max amount of debt that the sender is willing to accept to be borrowed.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  function rollFixed(
    Market market,
    uint256 repayMaturity,
    uint256 borrowMaturity,
    uint256 maxRepayAssets,
    uint256 maxBorrowAssets,
    uint256 percentage
  ) public msgSender {
    RollVars memory r;
    r.amounts = new uint256[](1);
    r.tokens = new ERC20[](1);
    r.tokens[0] = market.asset();
    address sender = _msgSender;

    (r.principal, r.fee) = market.fixedBorrowPositions(borrowMaturity, sender);
    (r.repayAssets, r.positionAssets) = repayAtMaturityAssets(market, repayMaturity, percentage);

    r.loopCount = r.repayAssets.mulDivUp(1, r.tokens[0].balanceOf(address(balancerVault)));
    if (r.loopCount > 1 && repayMaturity == borrowMaturity) revert InvalidOperation();

    r.amounts[0] = r.repayAssets.mulDivUp(1, r.loopCount);
    r.positionAssets = r.positionAssets / r.loopCount;
    r.calls = new bytes[](2 * r.loopCount);
    for (r.i = 0; r.i < r.loopCount; ) {
      r.calls[r.callIndex++] = abi.encodeCall(
        market.repayAtMaturity,
        (repayMaturity, r.positionAssets, type(uint256).max, sender)
      );
      r.calls[r.callIndex++] = abi.encodeCall(
        market.borrowAtMaturity,
        (
          borrowMaturity,
          r.amounts[0],
          type(uint256).max,
          r.i + 1 == r.loopCount ? address(balancerVault) : address(this),
          sender
        )
      );
      unchecked {
        ++r.i;
      }
    }

    balancerVault.flashLoan(address(this), r.tokens, r.amounts, call(abi.encode(market, r.calls)));
    (uint256 newPrincipal, uint256 newFee) = market.fixedBorrowPositions(borrowMaturity, sender);
    if (
      newPrincipal + newFee >
      (
        maxBorrowAssets < type(uint256).max - r.principal - r.fee
          ? maxBorrowAssets + r.principal + r.fee
          : type(uint256).max
      ) ||
      newPrincipal >
      (maxRepayAssets < type(uint256).max - r.principal ? maxRepayAssets + r.principal : type(uint256).max)
    ) {
      revert Disagreement();
    }
  }

  /// @notice Rolls a percentage of the fixed position of `_msgSender` to another fixed pool
  /// after calling `market.permit`.
  /// @param market The Market to roll the position in.
  /// @param repayMaturity The maturity of the fixed pool that the position is being rolled from.
  /// @param borrowMaturity The maturity of the fixed pool that the position is being rolled to.
  /// @param maxRepayAssets Max amount of debt that the account is willing to accept to be repaid.
  /// @param maxBorrowAssets Max amount of debt that the sender is willing to accept to be borrowed.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  /// Permit `value` should be `maxBorrowAssets`.
  function rollFixed(
    Market market,
    uint256 repayMaturity,
    uint256 borrowMaturity,
    uint256 maxRepayAssets,
    uint256 maxBorrowAssets,
    uint256 percentage,
    Permit calldata p
  ) external permit(market, maxBorrowAssets, p) {
    rollFixed(market, repayMaturity, borrowMaturity, maxRepayAssets, maxBorrowAssets, percentage);
  }

  /// @notice Rolls a percentage of the fixed position of `_msgSender` to a floating position.
  /// @param market The Market to roll the position in.
  /// @param repayMaturity The maturity of the fixed pool that the position is being rolled from.
  /// @param maxRepayAssets Max amount of debt that the account is willing to accept to be repaid.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  function rollFixedToFloating(
    Market market,
    uint256 repayMaturity,
    uint256 maxRepayAssets,
    uint256 percentage
  ) public msgSender {
    RollVars memory r;
    r.amounts = new uint256[](1);
    r.tokens = new ERC20[](1);
    r.tokens[0] = market.asset();
    address sender = _msgSender;

    r.principal = floatingBorrowAssets(market);
    (uint256 repayAssets, uint256 positionAssets) = repayAtMaturityAssets(market, repayMaturity, percentage);
    r.loopCount = repayAssets.mulDivUp(1, r.tokens[0].balanceOf(address(balancerVault)));
    positionAssets = positionAssets / r.loopCount;

    r.amounts[0] = repayAssets.mulDivUp(1, r.loopCount);
    r.calls = new bytes[](2 * r.loopCount);
    for (r.i = 0; r.i < r.loopCount; ) {
      r.calls[r.callIndex++] = abi.encodeCall(
        market.repayAtMaturity,
        (repayMaturity, positionAssets, type(uint256).max, sender)
      );
      r.calls[r.callIndex++] = abi.encodeCall(
        market.borrow,
        (r.amounts[0], r.i + 1 == r.loopCount ? address(balancerVault) : address(this), sender)
      );
      unchecked {
        ++r.i;
      }
    }
    balancerVault.flashLoan(address(this), r.tokens, r.amounts, call(abi.encode(market, r.calls)));
    if (maxRepayAssets < floatingBorrowAssets(market) - r.principal) revert Disagreement();
  }

  /// @notice Rolls a percentage of the fixed position of `_msgSender` to a floating position
  /// after calling `market.permit`.
  /// @param market The Market to roll the position in.
  /// @param repayMaturity The maturity of the fixed pool that the position is being rolled from.
  /// @param maxRepayAssets Max amount of debt that the account is willing to accept to be repaid.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  /// Permit `value` should be `maxRepayAssets`.
  function rollFixedToFloating(
    Market market,
    uint256 repayMaturity,
    uint256 maxRepayAssets,
    uint256 percentage,
    Permit calldata p
  ) external permit(market, maxRepayAssets, p) {
    rollFixedToFloating(market, repayMaturity, maxRepayAssets, percentage);
  }

  /// @notice Rolls a percentage of the floating position of `_msgSender` to a fixed position.
  /// @param market The Market to roll the position in.
  /// @param borrowMaturity The maturity of the fixed pool that the position is being rolled to.
  /// @param maxBorrowAssets Max amount of debt that the sender is willing to accept to be borrowed.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  function rollFloatingToFixed(
    Market market,
    uint256 borrowMaturity,
    uint256 maxBorrowAssets,
    uint256 percentage
  ) public msgSender {
    RollVars memory r;
    r.amounts = new uint256[](1);
    r.tokens = new ERC20[](1);
    r.tokens[0] = market.asset();
    address sender = _msgSender;

    (r.principal, r.fee) = market.fixedBorrowPositions(borrowMaturity, sender);
    r.repayAssets = floatingBorrowAssets(market);
    if (percentage < 1e18) r.repayAssets = r.repayAssets.mulWadDown(percentage);
    r.loopCount = r.repayAssets.mulDivUp(1, r.tokens[0].balanceOf(address(balancerVault)));

    r.amounts[0] = r.repayAssets.mulDivUp(1, r.loopCount);
    r.calls = new bytes[](2 * r.loopCount);
    for (r.i = 0; r.i < r.loopCount; ) {
      r.calls[r.callIndex++] = abi.encodeCall(market.repay, (r.amounts[0], sender));
      r.calls[r.callIndex++] = abi.encodeCall(
        market.borrowAtMaturity,
        (
          borrowMaturity,
          r.amounts[0],
          type(uint256).max,
          r.i + 1 == r.loopCount ? address(balancerVault) : address(this),
          sender
        )
      );
      unchecked {
        ++r.i;
      }
    }

    balancerVault.flashLoan(address(this), r.tokens, r.amounts, call(abi.encode(market, r.calls)));
    (uint256 newPrincipal, uint256 newFee) = market.fixedBorrowPositions(borrowMaturity, sender);
    if (maxBorrowAssets < newPrincipal + newFee - r.principal - r.fee) revert Disagreement();
  }

  /// @notice Rolls a percentage of the floating position of `_msgSender` to a fixed position
  /// after calling `market.permit`.
  /// @param market The Market to roll the position in.
  /// @param borrowMaturity The maturity of the fixed pool that the position is being rolled to.
  /// @param maxBorrowAssets Max amount of debt that the sender is willing to accept to be borrowed.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  /// Permit `value` should be `maxBorrowAssets`.
  function rollFloatingToFixed(
    Market market,
    uint256 borrowMaturity,
    uint256 maxBorrowAssets,
    uint256 percentage,
    Permit calldata p
  ) external permit(market, maxBorrowAssets, p) {
    rollFloatingToFixed(market, borrowMaturity, maxBorrowAssets, percentage);
  }

  /// @notice Calculates the actual repay and position assets of a repay operation at maturity.
  /// @param market The Market to calculate the actual repay and position assets.
  /// @param maturity The maturity of the fixed pool in which the position is being repaid.
  /// @param percentage The percentage of the position that will be repaid, represented with 18 decimals.
  /// @return actualRepay The actual amount of assets that will be repaid.
  /// @return positionAssets The amount of principal and fee to be covered.
  function repayAtMaturityAssets(
    Market market,
    uint256 maturity,
    uint256 percentage
  ) internal view returns (uint256 actualRepay, uint256 positionAssets) {
    FixedLib.Position memory position;
    (position.principal, position.fee) = market.fixedBorrowPositions(maturity, _msgSender);
    positionAssets = percentage < 1e18
      ? percentage.mulWadDown(position.principal + position.fee)
      : position.principal + position.fee;
    if (block.timestamp < maturity) {
      FixedLib.Pool memory pool;
      (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
      pool.unassignedEarnings -= pool.unassignedEarnings.mulDivDown(
        block.timestamp - pool.lastAccrual,
        maturity - pool.lastAccrual
      );
      (uint256 yield, ) = pool.calculateDeposit(
        position.scaleProportionally(positionAssets).principal,
        market.backupFeeRate()
      );
      actualRepay = positionAssets - yield;
    } else {
      actualRepay = positionAssets + positionAssets.mulWadDown((block.timestamp - maturity) * market.penaltyRate());
    }
  }

  /// @notice Hash of the call data that will be used to verify that the flash loan is originated from `this`.
  bytes32 private callHash;

  /// @notice Hashes the data and stores its value in `callHash`.
  /// @param data The calldata to be hashed.
  /// @return Same calldata that was passed as an argument.
  function call(bytes memory data) internal returns (bytes memory) {
    callHash = keccak256(data);
    return data;
  }

  /// @notice Calculates the crossed principal amount for a given `sender` in the input and output markets.
  /// @param marketIn The Market to withdraw the leveraged position.
  /// @param marketOut The Market to repay the leveraged position.
  /// @param sender The account that will be deleveraged.
  /// @param withdraw The amount of assets that will be withdrawn from `marketIn` to `sender`.
  function crossedPrincipal(
    Market marketIn,
    Market marketOut,
    address sender,
    uint256 withdraw
  ) internal view returns (uint256) {
    (, , , , IPriceFeed priceFeedIn) = auditor.markets(marketIn);
    (, , , , IPriceFeed priceFeedOut) = auditor.markets(marketOut);
    uint256 assetPriceIn = auditor.assetPrice(priceFeedIn);

    uint256 collateralUSD = (marketIn.maxWithdraw(sender) - floatingBorrowAssets(marketIn) - withdraw).mulWadDown(
      assetPriceIn
    ) * 10 ** (18 - marketIn.decimals());
    uint256 debtUSD = floatingBorrowAssets(marketOut).mulWadDown(auditor.assetPrice(priceFeedOut)) *
      10 ** (18 - marketOut.decimals());
    return (collateralUSD - debtUSD).divWadDown(assetPriceIn) / 10 ** (18 - marketIn.decimals());
  }

  /// @notice Returns the amount of `marketOut` underlying assets considering `amountIn` and both assets oracle prices.
  /// @param marketIn The market of the assets accounted as `amountIn`.
  /// @param marketOut The market of the assets that will be returned.
  /// @param amountIn The amount of `marketIn` underlying assets.
  function previewAssetsOut(Market marketIn, Market marketOut, uint256 amountIn) internal view returns (uint256) {
    (, , , , IPriceFeed priceFeedIn) = auditor.markets(marketIn);
    (, , , , IPriceFeed priceFeedOut) = auditor.markets(marketOut);

    return
      amountIn.mulDivDown(auditor.assetPrice(priceFeedIn), 10 ** marketIn.decimals()).mulDivDown(
        10 ** marketOut.decimals(),
        auditor.assetPrice(priceFeedOut)
      );
  }

  /// @notice Callback function called by the Balancer Vault contract when a flash loan is initiated.
  /// @dev Only the Balancer Vault contract is allowed to call this function.
  /// @param userData Additional data provided by the borrower for the flash loan.
  function receiveFlashLoan(ERC20[] memory, uint256[] memory, uint256[] memory, bytes memory userData) external {
    bytes32 memCallHash = callHash;
    assert(msg.sender == address(balancerVault) && memCallHash != bytes32(0) && memCallHash == keccak256(userData));
    callHash = bytes32(0);

    (Market market, bytes[] memory calls) = abi.decode(userData, (Market, bytes[]));
    for (uint256 i = 0; i < calls.length; ) {
      address(market).functionCall(calls[i], "");
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Callback function called by the Uniswap V3 pool contract when a swap is initiated.
  /// @dev Only the Uniswap V3 pool contract is allowed to call this function.
  /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
  /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
  /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
  /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
  /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call
  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
    SwapCallbackData memory s = abi.decode(data, (SwapCallbackData));
    PoolKey memory poolKey = PoolAddress.getPoolKey(s.assetIn, s.assetOut, s.fee);
    assert(msg.sender == PoolAddress.computeAddress(uniswapV3Factory, poolKey));

    if (s.leverage) {
      s.marketIn.deposit(
        s.principal + uint256(-(s.assetIn == poolKey.token0 ? amount0Delta : amount1Delta)),
        s.account
      );
      s.marketOut.borrow(uint256(s.assetIn == poolKey.token1 ? amount0Delta : amount1Delta), msg.sender, s.account);
    } else {
      s.marketOut.repay(uint256(-(s.assetIn == poolKey.token1 ? amount0Delta : amount1Delta)), s.account);
      s.marketIn.withdraw(uint256(s.assetIn == poolKey.token1 ? amount1Delta : amount0Delta), msg.sender, s.account);
      s.marketIn.withdraw(s.principal, s.account, s.account);
    }
  }

  address private _msgSender;

  modifier msgSender() {
    if (_msgSender == address(0)) _msgSender = msg.sender;
    _;
    delete _msgSender;
  }

  /// @notice Calls `token.permit` on behalf of `permit.account`.
  /// @param token The `ERC20` to call `permit`.
  /// @param assets The amount of assets to allow.
  /// @param p Arguments for the permit call.
  modifier permit(
    ERC20 token,
    uint256 assets,
    Permit calldata p
  ) {
    token.permit(p.account, address(this), assets, p.deadline, p.v, p.r, p.s);
    {
      address sender = _msgSender;
      if (sender == address(0)) _msgSender = p.account;
      else assert(p.account == sender);
    }
    _;
    assert(_msgSender == address(0));
  }

  /// @notice Calls `permit2.permitTransferFrom` to transfer `_msgSender` assets.
  /// @param token The `ERC20` to transfer from `_msgSender` to this contract.
  /// @param assets The amount of assets to transfer from `_msgSender`.
  /// @param p2 Arguments for the permit2 call.
  modifier permitTransfer(
    ERC20 token,
    uint256 assets,
    Permit2 calldata p2
  ) {
    {
      address sender = _msgSender;
      permit2.permitTransferFrom(
        IPermit2.PermitTransferFrom(
          IPermit2.TokenPermissions(address(token), assets),
          uint256(keccak256(abi.encode(sender, token, assets, p2.deadline))),
          p2.deadline
        ),
        IPermit2.SignatureTransferDetails(address(this), assets),
        sender,
        p2.signature
      );
    }
    _;
  }

  /// @notice Approves the Market to spend the contract's balance of the underlying asset.
  /// @dev The Market must be listed by the Auditor in order to be valid for approval.
  /// @param market The Market to spend the contract's balance.
  function approve(Market market) public {
    (, , , bool isListed, ) = auditor.markets(market);
    if (!isListed) revert MarketNotListed();

    market.asset().safeApprove(address(market), type(uint256).max);
  }

  function transferIn(Market market, uint256 assets) internal {
    if (assets != 0) market.asset().safeTransferFrom(_msgSender, address(this), assets);
  }

  function floatingBorrowAssets(Market market) internal view returns (uint256) {
    (, , uint256 floatingBorrowShares) = market.accounts(_msgSender);
    return market.previewRefund(floatingBorrowShares);
  }
}

error InvalidOperation();

struct Permit {
  address account;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}

struct Permit2 {
  uint256 deadline;
  bytes signature;
}

struct SwapCallbackData {
  Market marketIn;
  Market marketOut;
  address assetIn;
  address assetOut;
  address account;
  uint256 principal;
  uint24 fee;
  bool leverage;
}

struct RollVars {
  uint256[] amounts;
  ERC20[] tokens;
  bytes[] calls;
  uint256 positionAssets;
  uint256 repayAssets;
  uint256 callIndex;
  uint256 loopCount;
  uint256 principal;
  uint256 fee;
  uint256 i;
}

struct LeverageVars {
  address sender;
  address assetIn;
  address assetOut;
  uint256 amount;
}

interface IBalancerVault {
  function flashLoan(
    address recipient,
    ERC20[] memory tokens,
    uint256[] memory amounts,
    bytes memory userData
  ) external;
}

interface IPermit2 {
  struct TokenPermissions {
    address token;
    uint256 amount;
  }

  struct PermitTransferFrom {
    TokenPermissions permitted;
    uint256 nonce;
    uint256 deadline;
  }

  struct SignatureTransferDetails {
    address to;
    uint256 requestedAmount;
  }

  function permitTransferFrom(
    PermitTransferFrom memory permit,
    SignatureTransferDetails calldata transferDetails,
    address owner,
    bytes calldata signature
  ) external;

  // solhint-disable-next-line func-name-mixedcase
  function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IUniswapV3Pool {
  function swap(
    address recipient,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata data
  ) external returns (int256 amount0, int256 amount1);

  function slot0()
    external
    view
    returns (
      uint160 sqrtPriceX96,
      int24 tick,
      uint16 observationIndex,
      uint16 observationCardinality,
      uint16 observationCardinalityNext,
      uint8 feeProtocol,
      bool unlocked
    );
}

// https://github.com/Uniswap/v3-periphery/pull/271
library PoolAddress {
  bytes32 internal constant POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

  function getPoolKey(address tokenA, address tokenB, uint24 fee) internal pure returns (PoolKey memory) {
    if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    return PoolKey({ token0: tokenA, token1: tokenB, fee: fee });
  }

  function computeAddress(address uniswapV3Factory, PoolKey memory key) internal pure returns (address pool) {
    assert(key.token0 < key.token1);
    pool = address(
      uint160(
        uint256(
          keccak256(
            abi.encodePacked(
              hex"ff",
              uniswapV3Factory,
              keccak256(abi.encode(key.token0, key.token1, key.fee)),
              POOL_INIT_CODE_HASH
            )
          )
        )
      )
    );
  }
}

struct PoolKey {
  address token0;
  address token1;
  uint24 fee;
}
