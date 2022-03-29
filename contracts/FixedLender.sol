// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@rari-capital/solmate/src/utils/ReentrancyGuard.sol";
import { FixedPointMathLib } from "@rari-capital/solmate-v6/src/utils/FixedPointMathLib.sol";

import { ERC4626, ERC20, SafeTransferLib } from "@rari-capital/solmate/src/mixins/ERC4626.sol";
import { PoolLib, InsufficientProtocolLiquidity } from "./utils/PoolLib.sol";
import { IInterestRateModel } from "./interfaces/IInterestRateModel.sol";
import { PoolAccounting } from "./PoolAccounting.sol";
import { IAuditor } from "./interfaces/IAuditor.sol";
import { TSUtils } from "./utils/TSUtils.sol";

contract FixedLender is ERC4626, AccessControl, PoolAccounting, ReentrancyGuard, Pausable {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;

  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

  string public assetSymbol;
  IAuditor public immutable auditor;

  uint8 public maxFuturePools = 12; // if every 7 days, then 3 months

  uint256 public smartPoolBalance;

  // Total borrows in all maturities
  uint256 public totalMpBorrows;

  /// @notice Event emitted when a user borrows amount of an asset from a certain maturity date.
  /// @param to address which borrowed the asset.
  /// @param amount of the asset that it was borrowed.
  /// @param fee amount extra that it will need to be paid at maturity.
  /// @param maturityDate dateID/poolID/maturity in which the user will have to repay the loan.
  event BorrowFromMaturityPool(address indexed to, uint256 amount, uint256 fee, uint256 maturityDate);

  /// @notice Event emitted when a user deposits an amount of an asset to a certain maturity date collecting a fee at
  /// the end of the period.
  /// @param from address which deposited the asset.
  /// @param amount of the asset that it was deposited.
  /// @param fee is the extra amount that it will be collected at maturity.
  /// @param maturityDate dateID/poolID/maturity in which the user will be able to collect his deposit + his fee.
  event DepositToMaturityPool(address indexed from, uint256 amount, uint256 fee, uint256 maturityDate);

  /// @notice Event emitted when a user collects its deposits after maturity.
  /// @param from address which will be collecting the asset.
  /// @param amount of the asset that it was deposited.
  /// @param amountDiscounted of the asset that it was deposited (in case of early withdrawal).
  /// @param maturityDate poolID where the user collected its deposits.
  event WithdrawFromMaturityPool(address indexed from, uint256 amount, uint256 amountDiscounted, uint256 maturityDate);

  /// @notice Event emitted when a user repays its borrows after maturity.
  /// @param payer address which repaid the previously borrowed amount.
  /// @param borrower address which had the original debt.
  /// @param repayAmount amount that was repaid.
  /// @param debtCovered amount of the debt that was covered in this repayment (penalties could have been repaid).
  /// @param maturityDate poolID where the user repaid its borrowed amounts.
  event RepayToMaturityPool(
    address indexed payer,
    address indexed borrower,
    uint256 repayAmount,
    uint256 debtCovered,
    uint256 maturityDate
  );

  /// @notice Event emitted when a user's position had a liquidation.
  /// @param liquidator address which repaid the previously borrowed amount.
  /// @param borrower address which had the original debt.
  /// @param repayAmount amount of the asset that it was repaid.
  /// @param fixedLenderCollateral address of the asset that it was seized by the liquidator.
  /// @param seizedAmount amount seized of the collateral.
  /// @param maturityDate poolID where the borrower had an uncollaterized position.
  event LiquidateBorrow(
    address liquidator,
    address borrower,
    uint256 repayAmount,
    FixedLender fixedLenderCollateral,
    uint256 seizedAmount,
    uint256 maturityDate
  );

  /// @notice Event emitted when a user's collateral has been seized.
  /// @param liquidator address which seized this collateral.
  /// @param borrower address which had the original debt.
  /// @param seizedAmount amount seized of the collateral.
  event AssetSeized(address liquidator, address borrower, uint256 seizedAmount);

  constructor(
    ERC20 asset_,
    string memory assetSymbol_,
    IAuditor auditor_,
    IInterestRateModel _interestRateModel,
    uint256 _penaltyRate,
    uint256 _smartPoolReserveFactor
  )
    ERC4626(asset_, string(abi.encodePacked("EToken", assetSymbol_)), string(abi.encodePacked("e", assetSymbol_)))
    PoolAccounting(_interestRateModel, _penaltyRate, _smartPoolReserveFactor)
  {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

    assetSymbol = assetSymbol_;
    auditor = auditor_;
  }

  function totalAssets() public view override returns (uint256) {
    return smartPoolBalance;
  }

  function beforeWithdraw(uint256 assets, uint256) internal override {
    auditor.validateAccountShortfall(this, msg.sender, assets);

    // we check if the underlying liquidity that the user wants to withdraw is borrowed
    if (smartPoolBalance - assets < smartPoolBorrowed) revert InsufficientProtocolLiquidity();

    smartPoolBalance -= assets;
  }

  function afterDeposit(uint256 assets, uint256) internal virtual override whenNotPaused {
    smartPoolBalance += assets;
  }

  function transfer(address to, uint256 shares) public virtual override returns (bool) {
    auditor.validateAccountShortfall(this, msg.sender, convertToAssets(shares));
    return super.transfer(to, shares);
  }

  function transferFrom(
    address from,
    address to,
    uint256 shares
  ) public virtual override returns (bool) {
    auditor.validateAccountShortfall(this, msg.sender, convertToAssets(shares));
    return super.transferFrom(from, to, shares);
  }

  /// @dev Sets the protocol's max future weekly pools for borrowing and lending.
  /// @param _maxFuturePools number of pools to be active at the same time (4 weekly pools ~= 1 month).
  function setMaxFuturePools(uint8 _maxFuturePools) external onlyRole(DEFAULT_ADMIN_ROLE) {
    maxFuturePools = _maxFuturePools;
  }

  /// @dev Sets the _pause state to true in case of emergency, triggered by an authorized account.
  function pause() external onlyRole(PAUSER_ROLE) {
    _pause();
  }

  /// @dev Sets the _pause state to false when threat is gone, triggered by an authorized account.
  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  /// @notice Function to liquidate an uncollaterized position.
  /// @dev Msg.sender liquidates a borrower's position and repays a certain amount of debt for a maturity date,
  /// seizing a part of borrower's collateral.
  /// @param borrower wallet that has an outstanding debt for a certain maturity date.
  /// @param repayAmount amount to be repaid by liquidator(msg.sender).
  /// @param fixedLenderCollateral fixedLender from which the collateral will be seized to give the liquidator.
  /// @param maturityDate maturity date for which the position will be liquidated.
  function liquidate(
    address borrower,
    uint256 repayAmount,
    uint256 maxAmountAllowed,
    FixedLender fixedLenderCollateral,
    uint256 maturityDate
  ) external nonReentrant whenNotPaused returns (uint256) {
    return _liquidate(msg.sender, borrower, repayAmount, maxAmountAllowed, fixedLenderCollateral, maturityDate);
  }

  /// @notice Public function to seize a certain amount of tokens.
  /// @dev Public function for liquidator to seize borrowers tokens in the smart pool.
  /// This function will only be called from another FixedLender, on `liquidation` calls.
  /// That's why msg.sender needs to be passed to the private function (to be validated as a market)
  /// @param liquidator address which will receive the seized tokens.
  /// @param borrower address from which the tokens will be seized.
  /// @param seizeAmount amount to be removed from borrower's possession.
  function seize(
    address liquidator,
    address borrower,
    uint256 seizeAmount
  ) external nonReentrant whenNotPaused {
    _seize(FixedLender(msg.sender), liquidator, borrower, seizeAmount);
  }

  /// @dev Function to retrieve valid future pools.
  function getFuturePools() external view returns (uint256[] memory) {
    return TSUtils.futurePools(maxFuturePools);
  }

  /// @dev Lends to a wallet for a certain maturity date/pool.
  /// @param amount amount to send to the msg.sender.
  /// @param maturityDate maturity date for repayment.
  /// @param maxAmountAllowed maximum amount of debt that the user is willing to accept.
  function borrowFromMaturityPool(
    uint256 amount,
    uint256 maturityDate,
    uint256 maxAmountAllowed
  ) public nonReentrant whenNotPaused {
    // reverts on failure
    TSUtils.validateRequiredPoolState(maxFuturePools, maturityDate, TSUtils.State.VALID, TSUtils.State.NONE);

    (uint256 totalOwed, uint256 earningsSP) = borrowMP(
      maturityDate,
      msg.sender,
      amount,
      maxAmountAllowed,
      smartPoolBalance
    );
    totalMpBorrows += totalOwed;

    smartPoolBalance += earningsSP;
    auditor.validateBorrowMP(this, msg.sender);

    doTransferOut(msg.sender, amount);

    emit BorrowFromMaturityPool(msg.sender, amount, totalOwed - amount, maturityDate);
  }

  /// @dev Deposits a certain amount to the protocol for a certain maturity date/pool.
  /// @param amount amount to receive from the msg.sender.
  /// @param maturityDate maturity date / pool ID.
  /// @param minAmountRequired minimum amount of capital required by the depositor for the transaction to be accepted.
  function depositToMaturityPool(
    uint256 amount,
    uint256 maturityDate,
    uint256 minAmountRequired
  ) public nonReentrant whenNotPaused {
    // reverts on failure
    TSUtils.validateRequiredPoolState(maxFuturePools, maturityDate, TSUtils.State.VALID, TSUtils.State.NONE);

    doTransferIn(msg.sender, amount);

    (uint256 currentTotalDeposit, uint256 earningsSP) = depositMP(maturityDate, msg.sender, amount, minAmountRequired);

    smartPoolBalance += earningsSP;

    emit DepositToMaturityPool(msg.sender, amount, currentTotalDeposit - amount, maturityDate);
  }

  /// @notice User collects a certain amount of underlying asset after supplying tokens until a certain maturity date.
  /// @dev The pool that the user is trying to retrieve the money should be matured.
  /// @param redeemAmount The number of underlying tokens to receive.
  /// @param minAmountRequired minimum amount required by the user (if penalty fees for early withdrawal).
  /// @param maturityDate The matured date for which we're trying to retrieve the funds.
  function withdrawFromMaturityPool(
    uint256 redeemAmount,
    uint256 minAmountRequired,
    uint256 maturityDate
  ) public nonReentrant {
    if (redeemAmount == 0) revert ZeroRedeem();

    // reverts on failure
    TSUtils.validateRequiredPoolState(maxFuturePools, maturityDate, TSUtils.State.VALID, TSUtils.State.MATURED);

    // We check if there's any discount to be applied for early withdrawal
    (uint256 redeemAmountDiscounted, uint256 earningsSP) = withdrawMP(
      maturityDate,
      msg.sender,
      redeemAmount,
      minAmountRequired,
      smartPoolBalance
    );

    smartPoolBalance += earningsSP;

    doTransferOut(msg.sender, redeemAmountDiscounted);

    emit WithdrawFromMaturityPool(msg.sender, redeemAmount, redeemAmountDiscounted, maturityDate);
  }

  /// @notice Sender repays an amount of borrower's debt for a maturity date.
  /// @dev The pool that the user is trying to repay to should be matured.
  /// @param borrower The address of the account that has the debt.
  /// @param maturityDate The matured date where the debt is located.
  /// @param repayAmount amount to be paid for the borrower's debt.
  function repayToMaturityPool(
    address borrower,
    uint256 maturityDate,
    uint256 repayAmount,
    uint256 maxAmountAllowed
  ) public nonReentrant whenNotPaused {
    // reverts on failure
    TSUtils.validateRequiredPoolState(maxFuturePools, maturityDate, TSUtils.State.VALID, TSUtils.State.MATURED);

    _repay(msg.sender, borrower, maturityDate, repayAmount, maxAmountAllowed);
  }

  /// @dev Gets current snapshot for a wallet in certain maturity.
  /// @param who wallet to return status snapshot in the specified maturity date.
  /// @param maturityDate maturityDate. `PoolLib.MATURITY_ALL` (`type(uint256).max`) for all maturities.
  /// @return the amount the user deposited to the smart pool and the total money he owes from maturities.
  function getAccountSnapshot(address who, uint256 maturityDate) public view returns (uint256, uint256) {
    return (maxWithdraw(who), getAccountBorrows(who, maturityDate));
  }

  /// @notice This function allows to (partially) repay a position.
  /// @dev Internal repay function, allows partial repayment.
  /// Should be called after `beforeRepayMP` or `liquidateAllowed` on the auditor.
  /// @param payer the address of the account that will pay the debt.
  /// @param borrower the address of the account that has the debt.
  /// @param repayAmount the amount of debt of the pool that should be paid.
  /// @param maturityDate the maturityDate to access the pool.
  /// @return the actual amount that was transferred into the protocol.
  function _repay(
    address payer,
    address borrower,
    uint256 maturityDate,
    uint256 repayAmount,
    uint256 maxAmountAllowed
  ) internal returns (uint256) {
    if (repayAmount == 0) revert ZeroRepay();

    (uint256 actualRepayAmount, uint256 debtCovered, uint256 earningsSP) = repayMP(
      maturityDate,
      borrower,
      repayAmount,
      maxAmountAllowed
    );

    doTransferIn(payer, actualRepayAmount);

    smartPoolBalance += earningsSP;

    totalMpBorrows -= debtCovered;

    emit RepayToMaturityPool(payer, borrower, actualRepayAmount, debtCovered, maturityDate);

    return actualRepayAmount;
  }

  /// @notice Internal Function to liquidate an uncollaterized position.
  /// @dev Liquidator liquidates a borrower's position and repays a certain amount of collateral for a maturity date,
  /// seizing part of borrower's collateral.
  /// @param borrower wallet that has an outstanding debt for a certain maturity date.
  /// @param repayAmount amount to be repaid by liquidator(msg.sender).
  /// @param fixedLenderCollateral address of fixedLender from which the collateral will be seized.
  /// @param maturityDate maturity date for which the position will be liquidated.
  function _liquidate(
    address liquidator,
    address borrower,
    uint256 repayAmount,
    uint256 maxAmountAllowed,
    FixedLender fixedLenderCollateral,
    uint256 maturityDate
  ) internal returns (uint256) {
    // reverts on failure
    auditor.liquidateAllowed(this, fixedLenderCollateral, liquidator, borrower, repayAmount);

    repayAmount = _repay(liquidator, borrower, maturityDate, repayAmount, maxAmountAllowed);

    // reverts on failure
    uint256 seizeTokens = auditor.liquidateCalculateSeizeAmount(this, fixedLenderCollateral, repayAmount);

    // Revert if borrower collateral token balance < seizeTokens
    (uint256 balance, ) = fixedLenderCollateral.getAccountSnapshot(borrower, maturityDate);
    if (balance < seizeTokens) revert BalanceExceeded();

    // If this is also the collateral
    // run seizeInternal to avoid re-entrancy, otherwise make an external call
    // both revert on failure
    if (address(fixedLenderCollateral) == address(this)) {
      _seize(this, liquidator, borrower, seizeTokens);
    } else {
      fixedLenderCollateral.seize(liquidator, borrower, seizeTokens);
    }

    // We emit a LiquidateBorrow event
    emit LiquidateBorrow(liquidator, borrower, repayAmount, fixedLenderCollateral, seizeTokens, maturityDate);

    return repayAmount;
  }

  /// @notice Private function to seize a certain amount of tokens.
  /// @dev Private function for liquidator to seize borrowers tokens in the smart pool.
  /// Will only be called from this FixedLender on `liquidation` or through `seize` calls from another FixedLender.
  /// That's why msg.sender needs to be passed to the private function (to be validated as a market).
  /// @param seizerFixedLender address which is calling the seize function (see `seize` public function).
  /// @param liquidator address which will receive the seized tokens.
  /// @param borrower address from which the tokens will be seized.
  /// @param seizeAmount amount to be removed from borrower's possession.
  function _seize(
    FixedLender seizerFixedLender,
    address liquidator,
    address borrower,
    uint256 seizeAmount
  ) internal {
    // reverts on failure
    auditor.seizeAllowed(this, seizerFixedLender, liquidator, borrower);

    uint256 shares = previewWithdraw(seizeAmount);
    allowance[borrower][msg.sender] = shares;

    // That seize amount diminishes liquidity in the pool
    redeem(shares, liquidator, borrower);

    emit AssetSeized(liquidator, borrower, seizeAmount);
  }

  /// @notice Private function to safely transfer funds into this contract.
  /// @param from address which will transfer funds in (approve needed on underlying token).
  /// @param amount amount to be transferred.
  function doTransferIn(address from, uint256 amount) internal virtual {
    asset.safeTransferFrom(from, address(this), amount);
  }

  function doTransferOut(address to, uint256 amount) internal virtual {
    asset.safeTransfer(to, amount);
  }
}

error BalanceExceeded();
error NotFixedLender();
error ZeroRedeem();
error ZeroRepay();
