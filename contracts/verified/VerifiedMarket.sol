// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC20, FixedLib, Market, NotAuditor, RewardsController } from "../Market.sol";
import { NotAllowed, VerifiedAuditor } from "./VerifiedAuditor.sol";

/// @title VerifiedMarket
/// @notice Market contract that can only be used by allowed accounts.
contract VerifiedMarket is Market {
  /// @notice Amount of assets locked for an account.
  mapping(address account => uint256 assets) public lockedAssets;

  /// @dev Empty constructor for super call.
  constructor(ERC20 asset_, VerifiedAuditor auditor_) Market(asset_, auditor_) {}

  /// @notice Calls super function after requiring sender and receiver to be allowed.
  /// @param assets The amount of assets to deposit.
  /// @param receiver The address to receive the shares.
  function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
    _requireAllowed(msg.sender);
    _requireAllowed(receiver);
    return super.deposit(assets, receiver);
  }

  /// @notice Calls super function after requiring sender and receiver to be allowed.
  /// @param shares The amount of shares to mint.
  /// @param receiver The address to receive the assets.
  function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
    _requireAllowed(msg.sender);
    _requireAllowed(receiver);
    return super.mint(shares, receiver);
  }

  /// @notice Calls super function after requiring sender and receiver to be allowed.
  /// @param maturity The maturity of the deposit.
  /// @param assets The amount of assets to deposit.
  /// @param minAssetsRequired The minimum amount of assets required to deposit.
  /// @param receiver The address to receive the assets.
  /// @return The amount of assets deposited.
  function depositAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired,
    address receiver
  ) public override returns (uint256) {
    _requireAllowed(msg.sender);
    _requireAllowed(receiver);
    return super.depositAtMaturity(maturity, assets, minAssetsRequired, receiver);
  }

  /// @notice Locks remaining assets held by an account.
  /// @dev Can only be called by the auditor.
  ///   Burns the shares and removes the assets from total assets so the market does not account them anymore.
  /// @param account The account to lock the assets for.
  function lock(address account) external {
    _checkIsAuditor();

    uint256 shares = balanceOf[account];
    uint256 assets = convertToAssets(shares);
    beforeWithdraw(assets, shares);
    _burn(account, shares);

    // iterate over all the fixed deposits
    uint256 packedMaturities = accounts[account].fixedDeposits;
    uint256 maturity = packedMaturities & ((1 << 32) - 1);
    packedMaturities = packedMaturities >> 32;
    while (packedMaturities != 0) {
      if (packedMaturities & 1 != 0) {
        FixedLib.Position memory position = fixedDepositPositions[maturity][account];
        uint256 positionAssets = position.principal + position.fee;
        if (positionAssets != 0) {
          (uint256 assetsDiscounted, FixedLib.Pool storage pool, , ) = _prepareWithdrawAtMaturity(
            maturity,
            positionAssets,
            0,
            account
          );
          _processWithdrawAtMaturity(pool, position, maturity, positionAssets, account, assetsDiscounted);

          assets += assetsDiscounted;
        }
      }
      packedMaturities >>= 1;
      maturity += FixedLib.INTERVAL;
    }

    lockedAssets[account] += assets;

    emit Seize(msg.sender, account, assets);
    emit Locked(account, assets);
    emitMarketUpdate();
  }

  /// @notice Unlocks previously locked assets of an account.
  /// @dev Can only be called by the auditor.
  ///   Mints the shares and adds the assets to total assets so the market can account them again.
  /// @param account The account to unlock the assets for.
  function unlock(address account) external {
    _checkIsAuditor();

    uint256 lockedAssets_ = lockedAssets[account];
    if (lockedAssets_ == 0) return;

    lockedAssets[account] = 0;
    uint256 shares = previewDeposit(lockedAssets_);
    _mint(account, shares);
    afterDeposit(lockedAssets_, shares);
    emit Unlocked(account, lockedAssets_);
  }

  /// @notice Calls super function after requiring sender to be allowed.
  /// @param borrower The address of the borrower to liquidate.
  /// @param maxAssets The maximum amount of assets to liquidate.
  /// @param seizeMarket The market to seize the assets from.
  /// @return repaidAssets The amount of assets liquidated.
  function liquidate(
    address borrower,
    uint256 maxAssets,
    Market seizeMarket
  ) public override returns (uint256 repaidAssets) {
    _requireAllowed(msg.sender);
    return super.liquidate(borrower, maxAssets, seizeMarket);
  }

  /// @notice Calls super function after requiring sender and receiver to be allowed.
  /// @param borrowShares The amount of shares to refund.
  /// @param borrower The address of the borrower to refund.
  /// @return assets The amount of assets refunded.
  /// @return actualShares The amount of shares refunded.
  function refund(
    uint256 borrowShares,
    address borrower
  ) public override returns (uint256 assets, uint256 actualShares) {
    _requireAllowed(msg.sender);
    _requireAllowed(borrower);
    return super.refund(borrowShares, borrower);
  }

  /// @notice Calls super function after requiring sender and receiver to be allowed.
  /// @param assets The amount of assets to repay.
  /// @param borrower The address of the borrower to repay.
  /// @return actualRepay The amount of assets repaid.
  /// @return borrowShares The amount of shares repaid.
  function repay(uint256 assets, address borrower) public override returns (uint256 actualRepay, uint256 borrowShares) {
    _requireAllowed(msg.sender);
    _requireAllowed(borrower);
    return super.repay(assets, borrower);
  }

  /// @notice Calls super function after requiring sender and receiver to be allowed.
  /// @param maturity The maturity of the repayment.
  /// @param assets The amount of assets to repay.
  /// @param maxAssets The maximum amount of assets to repay.
  /// @param borrower The address of the borrower to repay.
  /// @return actualRepayAssets The amount of assets repaid.
  function repayAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 maxAssets,
    address borrower
  ) public override returns (uint256 actualRepayAssets) {
    _requireAllowed(msg.sender);
    _requireAllowed(borrower);
    return super.repayAtMaturity(maturity, assets, maxAssets, borrower);
  }

  /// @notice Calls super function after requiring to address to be allowed.
  /// @param to The address to transfer the shares to.
  /// @param shares The amount of shares to transfer.
  /// @return success The success of the transfer.
  function transfer(address to, uint256 shares) public override returns (bool) {
    _requireAllowed(to);
    return super.transfer(to, shares);
  }

  /// @notice Calls super function after requiring to address to be allowed.
  /// @param from The address to transfer the shares from.
  /// @param to The address to transfer the shares to.
  /// @param shares The amount of shares to transfer.
  /// @return success The success of the transfer.
  function transferFrom(address from, address to, uint256 shares) public override returns (bool) {
    _requireAllowed(to);
    return super.transferFrom(from, to, shares);
  }

  /// @notice Calls super function after requiring owner address to be allowed.
  /// @param maturity The maturity of the withdrawal.
  /// @param positionAssets The amount of assets to withdraw.
  /// @param minAssetsRequired The minimum amount of assets required to withdraw.
  /// @param receiver The address to receive the assets.
  /// @param owner The address of the owner to withdraw the assets for.
  /// @return assetsDiscounted The amount of assets discounted.
  function withdrawAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 minAssetsRequired,
    address receiver,
    address owner
  ) public override returns (uint256 assetsDiscounted) {
    _requireAllowed(owner);
    return super.withdrawAtMaturity(maturity, positionAssets, minAssetsRequired, receiver, owner);
  }

  /// @notice Empty function override, rewards not enabled.
  function handleRewards(bool, address) internal override {} // solhint-disable-line no-empty-blocks

  /// @notice Empty function override, rewards not enabled.
  function setRewardsController(RewardsController) public override {} // solhint-disable-line no-empty-blocks

  /// @notice Checks if an account is allowed on the firewall auditor.
  /// @dev Reverts if the account is not allowed.
  /// @param account The address to check.
  function _requireAllowed(address account) internal view {
    if (!VerifiedAuditor(address(auditor)).firewall().isAllowed(account)) revert NotAllowed(account);
  }

  /// @notice Checks that the sender is the auditor.
  /// @dev Reverts if the sender is not the auditor.
  function _checkIsAuditor() internal view {
    if (msg.sender != address(auditor)) revert NotAuditor();
  }
}

/// @notice Emitted when an account gets locked.
/// @param account The address of the account that got locked.
/// @param assets The amount of assets that got locked.
event Locked(address indexed account, uint256 assets);

/// @notice Emitted when an account gets unlocked.
/// @param account The address of the account that got unlocked.
/// @param assets The amount of assets that got unlocked.
event Unlocked(address indexed account, uint256 assets);
