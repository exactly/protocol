// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ERC4626, ERC20, SafeTransferLib } from "solmate/src/mixins/ERC4626.sol";
import { Auditor, Market } from "./Auditor.sol";

contract CollateralMarket is Initializable, AccessControlUpgradeable, PausableUpgradeable, ERC4626 {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;
  using SafeTransferLib for ERC20;

  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;

  /// @notice Accumulated earnings from extraordinary sources to be gradually distributed.
  uint256 public earningsAccumulator;
  /// @notice Last time the accumulator distributed earnings.
  uint32 public lastAccumulatorAccrual;
  /// @notice Factor used for gradual accrual of earnings to the floating pool.
  uint128 public earningsAccumulatorSmoothFactor;

  /// @notice Amount of floating assets deposited to the pool.
  uint256 public floatingAssets;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(ERC20 asset_, Auditor auditor_) ERC4626(asset_, "", "") {
    auditor = auditor_;

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize(uint128 earningsAccumulatorSmoothFactor_) external initializer {
    __AccessControl_init();
    __Pausable_init();

    string memory assetSymbol = asset.symbol();
    name = string.concat("exactly ", assetSymbol);
    symbol = string.concat("exa", assetSymbol);
    lastAccumulatorAccrual = uint32(block.timestamp);

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    setEarningsAccumulatorSmoothFactor(earningsAccumulatorSmoothFactor_);
  }

  /// @notice Public function to seize a certain amount of assets.
  /// @dev Public function for liquidator to seize borrowers assets in the floating pool.
  /// This function will only be called from another Market, on `liquidation` calls.
  /// @param liquidator address which will receive the seized assets.
  /// @param borrower address from which the assets will be seized.
  /// @param assets amount to be removed from borrower's possession.
  function seize(address liquidator, address borrower, uint256 assets) external virtual whenNotPaused {
    if (assets == 0) revert ZeroWithdraw();

    // reverts on failure
    auditor.checkSeize(Market(msg.sender), Market(address(this)));

    uint256 shares = previewWithdraw(assets);
    beforeWithdraw(assets, shares);
    _burn(borrower, shares);
    emit Withdraw(msg.sender, liquidator, borrower, assets, shares);
    emit Seize(liquidator, borrower, assets);
    emitMarketUpdate();

    asset.safeTransfer(liquidator, assets);
  }

  /// @notice Hook to update the floating pool average, floating pool balance and distribute earnings from accumulator.
  /// @dev It's expected that this function can't be paused to prevent freezing account funds.
  /// @param assets amount of assets to be withdrawn from the floating pool.
  function beforeWithdraw(uint256 assets, uint256) internal override {
    floatingAssets = floatingAssets + accrueAccumulatedEarnings() - assets;
  }

  /// @notice Hook to update the floating pool average, floating pool balance and distribute earnings from accumulator.
  /// @param assets amount of assets to be deposited to the floating pool.
  function afterDeposit(uint256 assets, uint256) internal override whenNotPaused {
    floatingAssets += accrueAccumulatedEarnings() + assets;
    emitMarketUpdate();
  }

  /// @notice Withdraws the owner's floating pool assets to the receiver address.
  /// @dev Makes sure that the owner doesn't have shortfall after withdrawing.
  /// @param assets amount of underlying to be withdrawn.
  /// @param receiver address to which the assets will be transferred.
  /// @param owner address which owns the floating pool assets.
  /// @return shares amount of shares redeemed for underlying asset.
  function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
    auditor.checkShortfall(Market(address(this)), owner, assets);
    shares = super.withdraw(assets, receiver, owner);
    emitMarketUpdate();
  }

  /// @notice Redeems the owner's floating pool assets to the receiver address.
  /// @dev Makes sure that the owner doesn't have shortfall after withdrawing.
  /// @param shares amount of shares to be redeemed for underlying asset.
  /// @param receiver address to which the assets will be transferred.
  /// @param owner address which owns the floating pool assets.
  /// @return assets amount of underlying asset that was withdrawn.
  function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
    auditor.checkShortfall(Market(address(this)), owner, previewRedeem(shares));
    assets = super.redeem(shares, receiver, owner);
    emitMarketUpdate();
  }

  /// @notice Moves amount of shares from the caller's account to `to`.
  /// @dev It's expected that this function can't be paused to prevent freezing account funds.
  /// Makes sure that the caller doesn't have shortfall after transferring.
  /// @param to address to which the assets will be transferred.
  /// @param shares amount of shares to be transferred.
  function transfer(address to, uint256 shares) public override returns (bool) {
    auditor.checkShortfall(Market(address(this)), msg.sender, previewRedeem(shares));
    return super.transfer(to, shares);
  }

  /// @notice Moves amount of shares from `from` to `to` using the allowance mechanism.
  /// @dev It's expected that this function can't be paused to prevent freezing account funds.
  /// Makes sure that `from` address doesn't have shortfall after transferring.
  /// @param from address from which the assets will be transferred.
  /// @param to address to which the assets will be transferred.
  /// @param shares amount of shares to be transferred.
  function transferFrom(address from, address to, uint256 shares) public override returns (bool) {
    auditor.checkShortfall(Market(address(this)), from, previewRedeem(shares));
    return super.transferFrom(from, to, shares);
  }

  /// @notice Gets current snapshot for an account across all maturities.
  /// @param account account to return status snapshot in the specified maturity date.
  /// @return the amount deposited to the floating pool.
  function accountSnapshot(address account) external view returns (uint256, uint256) {
    return (convertToAssets(balanceOf[account]), 0);
  }

  /// @notice Calculates the earnings to be distributed from the accumulator given the current timestamp.
  /// @return earnings to be distributed from the accumulator.
  function accumulatedEarnings() internal view returns (uint256 earnings) {
    uint256 elapsed = block.timestamp - lastAccumulatorAccrual;
    if (elapsed == 0) return 0;
    return earningsAccumulator.mulDivDown(elapsed, elapsed + earningsAccumulatorSmoothFactor.mulWadDown(1 weeks));
  }

  /// @notice Accrues the earnings to be distributed from the accumulator given the current timestamp.
  /// @return earnings distributed from the accumulator.
  function accrueAccumulatedEarnings() internal returns (uint256 earnings) {
    earnings = accumulatedEarnings();

    earningsAccumulator -= earnings;
    lastAccumulatorAccrual = uint32(block.timestamp);
    emit AccumulatorAccrual(block.timestamp);
  }

  /// @notice Calculates the floating pool balance plus earnings to be accrued at current timestamp.
  /// @return actual floatingAssets plus earnings to be accrued at current timestamp.
  function totalAssets() public view override returns (uint256) {
    return floatingAssets + accumulatedEarnings();
  }

  /// @notice Emits MarketUpdate event.
  /// @dev Internal function to avoid code duplication.
  function emitMarketUpdate() internal {
    emit MarketUpdate(block.timestamp, totalSupply, floatingAssets, earningsAccumulator);
  }

  /// @notice Sets the factor used when smoothly accruing earnings to the floating pool.
  /// @param earningsAccumulatorSmoothFactor_ represented with 18 decimals.
  function setEarningsAccumulatorSmoothFactor(
    uint128 earningsAccumulatorSmoothFactor_
  ) public onlyRole(DEFAULT_ADMIN_ROLE) {
    floatingAssets += accrueAccumulatedEarnings();
    emitMarketUpdate();
    earningsAccumulatorSmoothFactor = earningsAccumulatorSmoothFactor_;
    emit EarningsAccumulatorSmoothFactorSet(earningsAccumulatorSmoothFactor_);
  }

  /// @notice Sets the pause state to true in case of emergency, triggered by an authorized account.
  function pause() external onlyRole(PAUSER_ROLE) {
    _pause();
  }

  /// @notice Sets the pause state to false when threat is gone, triggered by an authorized account.
  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  /// @notice Emitted when an account's collateral has been seized.
  /// @param liquidator address which seized this collateral.
  /// @param borrower address which had the original debt.
  /// @param assets amount seized of the collateral.
  event Seize(address indexed liquidator, address indexed borrower, uint256 assets);

  /// @notice Emitted when the earningsAccumulatorSmoothFactor is changed by admin.
  /// @param earningsAccumulatorSmoothFactor factor represented with 18 decimals.
  event EarningsAccumulatorSmoothFactorSet(uint256 earningsAccumulatorSmoothFactor);

  /// @notice Emitted when market state is updated.
  /// @param timestamp current timestamp.
  /// @param floatingDepositShares total floating supply shares.
  /// @param floatingAssets total floating supply assets.
  event MarketUpdate(
    uint256 timestamp,
    uint256 floatingDepositShares,
    uint256 floatingAssets,
    uint256 earningsAccumulator
  );

  /// @notice Emitted when accumulator distributes earnings.
  /// @param timestamp current timestamp.
  event AccumulatorAccrual(uint256 timestamp);
}

error ZeroWithdraw();
