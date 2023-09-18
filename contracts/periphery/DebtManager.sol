// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { AddressUpgradeable as Address } from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {
  SafeERC20Upgradeable as SafeERC20,
  IERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { Market, ERC20, FixedLib, Disagreement } from "../Market.sol";
import { Auditor, IPriceFeed, MarketNotListed } from "../Auditor.sol";

/// @title DebtManager
/// @notice Contract for efficient debt management of accounts interacting with Exactly Protocol.
contract DebtManager is Initializable {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;
  using SafeERC20 for IERC20PermitUpgradeable;
  using FixedLib for FixedLib.Position;
  using FixedLib for FixedLib.Pool;
  using Address for address;

  /// @notice Maximum excess of allowance accepted, in percentage using 18 decimals.
  uint256 public constant MAX_ALLOWANCE_SURPLUS = 0.01e18;

  /// @notice Auditor contract that lists the markets that can be leveraged.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;
  /// @notice Permit2 contract to be used to transfer assets from accounts.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPermit2 public immutable permit2;
  /// @notice Balancer's vault contract that is used to take flash loans.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IBalancerVault public immutable balancerVault;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_, IPermit2 permit2_, IBalancerVault balancerVault_) {
    auditor = auditor_;
    permit2 = permit2_;
    balancerVault = balancerVault_;

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
  /// @param marketPermit Arguments for the permit call to `market` on behalf of `_msgSender`.
  /// @param assetPermit Arguments for the permit2 asset call.
  /// Permit `value` should be `borrowAssets`.
  function leverage(
    Market market,
    uint256 deposit,
    uint256 ratio,
    Permit calldata marketPermit,
    Permit2 calldata assetPermit
  ) external permit(market, marketPermit) permitTransfer(market.asset(), deposit, assetPermit) msgSender {
    noTransferLeverage(market, deposit, ratio);
  }

  /// @notice Leverages the floating position of `_msgSender` a certain `ratio` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  /// @param marketPermit Arguments for the permit call to `market` on behalf of `_msgSender`.
  /// @param assetPermit Arguments for the permit call to the market underlying asset.
  /// Permit `value` should be `borrowAssets`.
  function leverage(
    Market market,
    uint256 ratio,
    Permit calldata marketPermit,
    Permit calldata assetPermit
  ) external permit(market, marketPermit) permit(market.asset(), assetPermit) {
    leverage(market, assetPermit.value, ratio);
  }

  /// @notice Leverages the floating position of `_msgSender` a certain `ratio` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param deposit The amount of assets to deposit.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  /// @param marketPermit Arguments for the permit call to `market` on behalf of `_msgSender`.
  /// Permit `value` should be `borrowAssets`.
  function leverage(
    Market market,
    uint256 deposit,
    uint256 ratio,
    Permit calldata marketPermit
  ) external permit(market, marketPermit) msgSender {
    market.asset().safeTransferFrom(msg.sender, address(this), deposit);
    noTransferLeverage(market, deposit, ratio);
  }

  /// @notice Leverages the floating position of `_msgSender` a certain `ratio` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param deposit The amount of assets to deposit.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  function noTransferLeverage(Market market, uint256 deposit, uint256 ratio) internal {
    checkMarket(market);
    uint256[] memory amounts = new uint256[](1);
    ERC20[] memory tokens = new ERC20[](1);
    tokens[0] = market.asset();
    address sender = _msgSender;

    uint256 loopCount;
    {
      uint256 collateral = market.maxWithdraw(sender);
      uint256 targetDeposit = (collateral + deposit - floatingBorrowAssets(market)).mulWadDown(ratio);
      int256 amount = int256(targetDeposit) - int256(collateral + deposit);
      if (amount <= 0) {
        market.deposit(deposit, sender);
        return;
      }
      loopCount = uint256(amount).mulDivUp(1, tokens[0].balanceOf(address(balancerVault)));
      amounts[0] = uint256(amount).mulDivUp(1, loopCount);
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

    balancerVault.flashLoan(address(this), tokens, amounts, hash(abi.encode(market, calls)));
  }

  /// @notice Deleverages `_msgSender`'s position to a `ratio` via flash loan from Balancer's vault.
  /// @param market The Market to deleverage the position out.
  /// @param withdraw The amount of assets that will be withdrawn to `_msgSender`.
  /// @param ratio The ratio of the borrow that will be repaid, represented with 18 decimals.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  /// Permit `value` should be `permitAssets`.
  function deleverage(Market market, uint256 withdraw, uint256 ratio, Permit calldata p) external permit(market, p) {
    deleverage(market, withdraw, ratio);
  }

  /// @notice Deleverages `_msgSender`'s position to a `ratio` via flash loan from Balancer's vault.
  /// @param market The Market to deleverage the position out.
  /// @param withdraw The amount of assets that will be withdrawn to `_msgSender`.
  /// @param ratio The number of times that the current principal will be leveraged, represented with 18 decimals.
  function deleverage(Market market, uint256 withdraw, uint256 ratio) public msgSender {
    checkMarket(market);
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

    balancerVault.flashLoan(address(this), r.tokens, r.amounts, hash(abi.encode(market, r.calls)));
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
    checkMarket(market);
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

    balancerVault.flashLoan(address(this), r.tokens, r.amounts, hash(abi.encode(market, r.calls)));
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
  ) external permit(market, p) {
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
    checkMarket(market);
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
    balancerVault.flashLoan(address(this), r.tokens, r.amounts, hash(abi.encode(market, r.calls)));
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
  ) external permit(market, p) {
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
    checkMarket(market);
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

    balancerVault.flashLoan(address(this), r.tokens, r.amounts, hash(abi.encode(market, r.calls)));
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
  ) external permit(market, p) {
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
  /// @return data The same calldata that was passed as an argument.
  function hash(bytes memory data) internal returns (bytes memory) {
    callHash = keccak256(data);
    return data;
  }

  /// @notice Callback function called by the Balancer Vault contract when a flash loan is initiated.
  /// @dev Only the Balancer Vault contract is allowed to call this function.
  /// @param userData Additional data provided by the borrower for the flash loan.
  function receiveFlashLoan(ERC20[] memory, uint256[] memory, uint256[] memory, bytes memory userData) external {
    bytes32 memCallHash = callHash;
    assert(msg.sender == address(balancerVault) && memCallHash == keccak256(userData));
    callHash = bytes32(0);

    (Market market, bytes[] memory calls) = abi.decode(userData, (Market, bytes[]));
    checkMarket(market);
    for (uint256 i = 0; i < calls.length; ) {
      address(market).functionCall(calls[i], "");
      unchecked {
        ++i;
      }
    }
  }

  address private _msgSender;
  bool private _msgSenderSet;

  modifier msgSender() {
    if (_msgSender == address(0)) {
      _msgSender = msg.sender;
      _msgSenderSet = true;
    } else assert(!_msgSenderSet);
    _;
    delete _msgSender;
    delete _msgSenderSet;
  }

  function checkMarket(Market market) internal view {
    (, , , bool listed, ) = auditor.markets(market);
    if (!listed) revert MarketNotListed();
  }

  /// @notice Calls `token.permit` on behalf of `permit.account`.
  /// @param token The `ERC20` to call `permit`.
  /// @param p Arguments for the permit call.
  modifier permit(ERC20 token, Permit calldata p) {
    IERC20PermitUpgradeable(address(token)).safePermit(p.account, address(this), p.value, p.deadline, p.v, p.r, p.s);
    {
      address sender = _msgSender;
      if (sender == address(0)) _msgSender = p.account;
      else assert(p.account == sender);
    }
    _;
    assert(_msgSender == address(0));
    if (token.allowance(p.account, address(this)) > p.value.mulWadDown(MAX_ALLOWANCE_SURPLUS)) {
      revert AllowanceSurplus();
    }
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
    checkMarket(market);
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

error AllowanceSurplus();
error InvalidOperation();

struct Permit {
  address account;
  uint256 value;
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
