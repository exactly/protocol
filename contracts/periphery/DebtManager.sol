// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { AddressUpgradeable as Address } from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import { Market, ERC20, FixedLib, Disagreement } from "../Market.sol";
import { Auditor, MarketNotListed } from "../Auditor.sol";

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
    for (uint256 i = 0; i < markets.length; i++) {
      markets[i].asset().safeApprove(address(markets[i]), type(uint256).max);
    }
  }

  /// @notice Leverages the floating position of `msg.sender` to match `targetHealthFactor` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param principal The amount of assets to leverage.
  /// @param deposit The amount of assets to deposit.
  /// @param targetHealthFactor The desired target health factor that the account will be leveraged to.
  function leverage(Market market, uint256 principal, uint256 deposit, uint256 targetHealthFactor) external {
    if (deposit != 0) market.asset().safeTransferFrom(msg.sender, address(this), deposit);

    noTransferLeverage(market, principal, deposit, targetHealthFactor);
  }

  /// @notice Leverages the floating position of `msg.sender` to match `targetHealthFactor` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param principal The amount of assets to leverage.
  /// @param deposit The amount of assets to deposit.
  /// @param targetHealthFactor The desired target health factor that the account will be leveraged to.
  function noTransferLeverage(Market market, uint256 principal, uint256 deposit, uint256 targetHealthFactor) internal {
    uint256[] memory amounts = new uint256[](1);
    ERC20[] memory tokens = new ERC20[](1);
    bytes[] memory calls = new bytes[](2);

    (uint256 adjustFactor, , , , ) = auditor.markets(market);
    uint256 factor = adjustFactor.mulWadDown(adjustFactor).divWadDown(targetHealthFactor);
    tokens[0] = market.asset();
    amounts[0] = principal.mulWadDown(factor).divWadDown(1e18 - factor);
    calls[0] = abi.encodeCall(market.deposit, (amounts[0] + deposit, msg.sender));
    calls[1] = abi.encodeCall(market.borrow, (amounts[0], address(balancerVault), msg.sender));

    balancerVault.flashLoan(address(this), tokens, amounts, call(abi.encode(market, calls)));
  }

  /// @notice Deleverages the position of `msg.sender` a certain `percentage` by taking a flash loan from
  /// Balancer's vault to repay the borrow.
  /// @param market The Market to deleverage the position out.
  /// @param maturity The maturity of the fixed pool that the position is being deleveraged out of, `0` if floating.
  /// @param maxRepayAssets Max amount of fixed debt that the sender is willing to accept.
  /// @param percentage The percentage of the borrow that will be repaid, represented with 18 decimals.
  /// @param withdraw The amount of assets that will be withdrawn to `msg.sender`.
  function deleverage(
    Market market,
    uint256 maturity,
    uint256 maxRepayAssets,
    uint256 percentage,
    uint256 withdraw
  ) public {
    uint256[] memory amounts = new uint256[](1);
    ERC20[] memory tokens = new ERC20[](1);
    bytes[] memory calls = new bytes[](withdraw == 0 ? 2 : 3);
    tokens[0] = market.asset();

    if (maturity == 0) {
      (, , uint256 floatingBorrowShares) = market.accounts(msg.sender);
      amounts[0] = market.previewRefund(floatingBorrowShares.mulWadDown(percentage));
      calls[0] = abi.encodeCall(market.repay, (amounts[0], msg.sender));
    } else {
      uint256 positionAssets;
      (amounts[0], positionAssets) = repayAtMaturityAssets(market, maturity, percentage);
      calls[0] = abi.encodeCall(market.repayAtMaturity, (maturity, positionAssets, maxRepayAssets, msg.sender));
    }
    calls[1] = abi.encodeCall(market.withdraw, (amounts[0], address(balancerVault), msg.sender));
    if (withdraw > 0) calls[2] = abi.encodeCall(market.withdraw, (withdraw, msg.sender, msg.sender));

    balancerVault.flashLoan(address(this), tokens, amounts, call(abi.encode(market, calls)));
  }

  /// @notice Rolls a percentage of the floating position of `msg.sender` to a fixed position.
  /// @param market The Market to roll the position in.
  /// @param borrowMaturity The maturity of the fixed pool that the position is being rolled to.
  /// @param maxBorrowAssets Max amount of debt that the sender is willing to accept to be borrowed.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  function rollFloatingToFixed(
    Market market,
    uint256 borrowMaturity,
    uint256 maxBorrowAssets,
    uint256 percentage
  ) public {
    uint256[] memory amounts = new uint256[](1);
    ERC20[] memory tokens = new ERC20[](1);
    bytes[] memory calls;
    RollVars memory r;
    tokens[0] = market.asset();

    (r.principal, r.fee) = market.fixedBorrowPositions(borrowMaturity, msg.sender);
    (, , uint256 floatingBorrowShares) = market.accounts(msg.sender);
    r.repayAssets = market.previewRefund(
      percentage < 1e18 ? floatingBorrowShares.mulWadDown(percentage) : floatingBorrowShares
    );
    r.loopCount = r.repayAssets.mulDivUp(1, tokens[0].balanceOf(address(balancerVault)));

    amounts[0] = r.repayAssets.mulDivUp(1, r.loopCount);
    calls = new bytes[](2 * r.loopCount);
    for (r.i = 0; r.i < r.loopCount; ) {
      calls[r.callIndex++] = abi.encodeCall(
        market.repay,
        (r.i == 0 ? amounts[0] : r.repayAssets / r.loopCount, msg.sender)
      );
      calls[r.callIndex++] = abi.encodeCall(
        market.borrowAtMaturity,
        (
          borrowMaturity,
          r.i + 1 == r.loopCount ? amounts[0] : r.repayAssets / r.loopCount,
          type(uint256).max,
          r.i + 1 == r.loopCount ? address(balancerVault) : address(this),
          msg.sender
        )
      );
      unchecked {
        ++r.i;
      }
    }

    balancerVault.flashLoan(address(this), tokens, amounts, call(abi.encode(market, calls)));
    (uint256 newPrincipal, uint256 newFee) = market.fixedBorrowPositions(borrowMaturity, msg.sender);
    if (maxBorrowAssets < newPrincipal + newFee - r.principal - r.fee) revert Disagreement();
  }

  /// @notice Rolls a percentage of the fixed position of `msg.sender` to a floating position.
  /// @param market The Market to roll the position in.
  /// @param repayMaturity The maturity of the fixed pool that the position is being rolled from.
  /// @param maxRepayAssets Max amount of debt that the account is willing to accept to be repaid.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  function rollFixedToFloating(
    Market market,
    uint256 repayMaturity,
    uint256 maxRepayAssets,
    uint256 percentage
  ) public {
    uint256[] memory amounts = new uint256[](1);
    ERC20[] memory tokens = new ERC20[](1);
    bytes[] memory calls;
    RollVars memory r;
    tokens[0] = market.asset();

    {
      (, , uint256 floatingBorrowShares) = market.accounts(msg.sender);
      r.principal = market.previewRefund(floatingBorrowShares);
    }
    (uint256 repayAssets, uint256 positionAssets) = repayAtMaturityAssets(market, repayMaturity, percentage);
    r.loopCount = repayAssets.mulDivUp(1, tokens[0].balanceOf(address(balancerVault)));
    positionAssets = positionAssets / r.loopCount;

    amounts[0] = repayAssets.mulDivUp(1, r.loopCount);
    calls = new bytes[](2 * r.loopCount);
    for (r.i = 0; r.i < r.loopCount; ) {
      calls[r.callIndex++] = abi.encodeCall(
        market.repayAtMaturity,
        (repayMaturity, positionAssets, type(uint256).max, msg.sender)
      );
      calls[r.callIndex++] = abi.encodeCall(
        market.borrow,
        (amounts[0], r.i + 1 == r.loopCount ? address(balancerVault) : address(this), msg.sender)
      );
      unchecked {
        ++r.i;
      }
    }
    balancerVault.flashLoan(address(this), tokens, amounts, call(abi.encode(market, calls)));
    {
      (, , uint256 floatingBorrowShares) = market.accounts(msg.sender);
      if (maxRepayAssets < market.previewRefund(floatingBorrowShares) - r.principal) revert Disagreement();
    }
  }

  /// @notice Rolls a percentage of the fixed position of `msg.sender` to another fixed pool.
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
  ) public {
    uint256[] memory amounts = new uint256[](1);
    ERC20[] memory tokens = new ERC20[](1);
    bytes[] memory calls;
    RollVars memory r;
    tokens[0] = market.asset();

    (r.principal, r.fee) = market.fixedBorrowPositions(borrowMaturity, msg.sender);
    (r.repayAssets, r.positionAssets) = repayAtMaturityAssets(market, repayMaturity, percentage);

    r.loopCount = r.repayAssets.mulDivUp(1, tokens[0].balanceOf(address(balancerVault)));
    if (r.loopCount > 1 && repayMaturity == borrowMaturity) revert InvalidOperation();

    amounts[0] = r.repayAssets.mulDivUp(1, r.loopCount);
    r.positionAssets = r.positionAssets / r.loopCount;
    calls = new bytes[](2 * r.loopCount);
    for (r.i = 0; r.i < r.loopCount; ) {
      calls[r.callIndex++] = abi.encodeCall(
        market.repayAtMaturity,
        (repayMaturity, r.positionAssets, type(uint256).max, msg.sender)
      );
      calls[r.callIndex++] = abi.encodeCall(
        market.borrowAtMaturity,
        (
          borrowMaturity,
          amounts[0],
          type(uint256).max,
          r.i + 1 == r.loopCount ? address(balancerVault) : address(this),
          msg.sender
        )
      );
      unchecked {
        ++r.i;
      }
    }

    balancerVault.flashLoan(address(this), tokens, amounts, call(abi.encode(market, calls)));
    (uint256 newPrincipal, uint256 newFee) = market.fixedBorrowPositions(borrowMaturity, msg.sender);
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
    (position.principal, position.fee) = market.fixedBorrowPositions(maturity, msg.sender);
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

  /// @notice Calls `token.permit` on behalf of `permit.account`.
  /// @param token The `ERC20` to call `permit`.
  /// @param p Arguments for the permit call.
  modifier permit(
    ERC20 token,
    uint256 assets,
    Permit calldata p
  ) {
    token.permit(p.account, address(this), assets, p.deadline, p.v, p.r, p.s);
    _;
  }

  /// @notice Calls `permit2.permitTransferFrom` to transfer `msg.sender` assets.
  /// @param token The `ERC20` to transfer from `msg.sender` to this contract.
  /// @param assets The amount of assets to transfer from `msg.sender`.
  /// @param deadline The deadline for the permit call.
  /// @param signature The signature for the permit call.
  modifier permitTransfer(
    ERC20 token,
    uint256 assets,
    uint256 deadline,
    bytes calldata signature
  ) {
    permit2.permitTransferFrom(
      IPermit2.PermitTransferFrom(
        IPermit2.TokenPermissions(address(token), assets),
        uint256(keccak256(abi.encode(msg.sender, token, assets, deadline))),
        deadline
      ),
      IPermit2.SignatureTransferDetails(address(this), assets),
      msg.sender,
      signature
    );
    _;
  }

  /// @notice Leverages the floating position of `msg.sender` to match `targetHealthFactor` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param principal The amount of assets to leverage.
  /// @param deposit The amount of assets to deposit.
  /// @param targetHealthFactor The desired target health factor that the account will be leveraged to.
  /// @param deadline The deadline for the permit call.
  /// @param signature The signature for the permit call.
  function leverage(
    Market market,
    uint256 principal,
    uint256 deposit,
    uint256 targetHealthFactor,
    uint256 deadline,
    bytes calldata signature
  ) external permitTransfer(market.asset(), deposit, deadline, signature) {
    noTransferLeverage(market, principal, deposit, targetHealthFactor);
  }

  /// @notice Deleverages the position of `msg.sender` a certain `percentage` by taking a flash loan from
  /// Balancer's vault to repay the borrow.
  /// @param market The Market to deleverage the position out.
  /// @param maturity The maturity of the fixed pool that the position is being deleveraged out of, `0` if floating.
  /// @param maxRepayAssets Max amount of fixed debt that the sender is willing to accept.
  /// @param percentage The percentage of the borrow that will be repaid, represented with 18 decimals.
  /// @param withdraw The amount of assets that will be withdrawn to `msg.sender`.
  /// @param permitAssets The amount of assets to allow this contract to withdraw on behalf of `msg.sender`.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  function deleverage(
    Market market,
    uint256 maturity,
    uint256 maxRepayAssets,
    uint256 percentage,
    uint256 withdraw,
    uint256 permitAssets,
    Permit calldata p
  ) external permit(market, permitAssets, p) {
    deleverage(market, maturity, maxRepayAssets, percentage, withdraw);
  }

  /// @notice Rolls a percentage of the floating position of `msg.sender` to a fixed position
  /// after calling `market.permit`.
  /// @param market The Market to roll the position in.
  /// @param borrowMaturity The maturity of the fixed pool that the position is being rolled to.
  /// @param maxBorrowAssets Max amount of debt that the sender is willing to accept to be borrowed.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  function rollFloatingToFixed(
    Market market,
    uint256 borrowMaturity,
    uint256 maxBorrowAssets,
    uint256 percentage,
    Permit calldata p
  ) external permit(market, maxBorrowAssets, p) {
    rollFloatingToFixed(market, borrowMaturity, maxBorrowAssets, percentage);
  }

  /// @notice Rolls a percentage of the fixed position of `msg.sender` to a floating position
  /// after calling `market.permit`.
  /// @param market The Market to roll the position in.
  /// @param repayMaturity The maturity of the fixed pool that the position is being rolled from.
  /// @param maxRepayAssets Max amount of debt that the account is willing to accept to be repaid.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  function rollFixedToFloating(
    Market market,
    uint256 repayMaturity,
    uint256 maxRepayAssets,
    uint256 percentage,
    Permit calldata p
  ) external permit(market, maxRepayAssets, p) {
    rollFixedToFloating(market, repayMaturity, maxRepayAssets, percentage);
  }

  /// @notice Rolls a percentage of the fixed position of `msg.sender` to another fixed pool
  /// after calling `market.permit`.
  /// @param market The Market to roll the position in.
  /// @param repayMaturity The maturity of the fixed pool that the position is being rolled from.
  /// @param borrowMaturity The maturity of the fixed pool that the position is being rolled to.
  /// @param maxRepayAssets Max amount of debt that the account is willing to accept to be repaid.
  /// @param maxBorrowAssets Max amount of debt that the sender is willing to accept to be borrowed.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
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

  /// @notice Returns Balancer Vault's available liquidity of each enabled underlying asset.
  function availableLiquidity() external view returns (AvailableAsset[] memory availableAssets) {
    uint256 marketsCount = auditor.allMarkets().length;
    availableAssets = new AvailableAsset[](marketsCount);

    for (uint256 i = 0; i < marketsCount; i++) {
      ERC20 asset = auditor.marketList(i).asset();
      availableAssets[i] = AvailableAsset({ asset: asset, liquidity: asset.balanceOf(address(balancerVault)) });
    }
  }

  /// @notice Approves the Market to spend the contract's balance of the underlying asset.
  /// @dev The Market must be listed by the Auditor in order to be valid for approval.
  /// @param market The Market to spend the contract's balance.
  function approve(Market market) external {
    (, , , bool isListed, ) = auditor.markets(market);
    if (!isListed) revert MarketNotListed();

    market.asset().safeApprove(address(market), type(uint256).max);
  }

  struct AvailableAsset {
    ERC20 asset;
    uint256 liquidity;
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

struct RollVars {
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
