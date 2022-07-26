// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@rari-capital/solmate/src/utils/ReentrancyGuard.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { ERC4626, ERC20, SafeTransferLib } from "@rari-capital/solmate/src/mixins/ERC4626.sol";
import { PoolLib, InsufficientProtocolLiquidity } from "./utils/PoolLib.sol";
import { Auditor, InvalidParameter } from "./Auditor.sol";
import { InterestRateModel } from "./InterestRateModel.sol";
import { TSUtils } from "./utils/TSUtils.sol";

contract FixedLender is ERC4626, AccessControl, ReentrancyGuard, Pausable {
  using FixedPointMathLib for int256;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;
  using SafeTransferLib for ERC20;
  using PoolLib for PoolLib.FixedPool;
  using PoolLib for PoolLib.Position;
  using PoolLib for uint256;

  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  uint256 public constant CLOSE_FACTOR = 5e17;

  struct DampSpeed {
    uint256 up;
    uint256 down;
  }

  mapping(uint256 => mapping(address => PoolLib.Position)) public fixedDepositPositions;
  mapping(uint256 => mapping(address => PoolLib.Position)) public fixedBorrowPositions;
  mapping(address => uint256) public flexibleBorrowPositions;

  mapping(address => uint256) public fixedBorrows;
  mapping(address => uint256) public fixedDeposits;
  mapping(uint256 => PoolLib.FixedPool) public fixedPools;

  /// @notice Total amount of smart pool assets borrowed from maturities (not counting fees).
  uint256 public smartPoolFixedBorrows;
  /// @notice Total amount of smart pool assets borrowed directly from the smart pool (counting flexible debt).
  uint256 public smartPoolFlexibleBorrows;

  uint256 public smartPoolEarningsAccumulator;
  uint256 public penaltyRate;
  uint256 public smartPoolFeeRate;
  uint256 public dampSpeedUp;
  uint256 public dampSpeedDown;

  uint8 public maxFuturePools;
  uint32 public lastAccumulatedEarningsAccrual;
  uint32 public lastAverageUpdate;

  InterestRateModel public interestRateModel;
  Auditor public immutable auditor;

  uint128 public accumulatedEarningsSmoothFactor;
  uint128 public smartPoolReserveFactor;

  uint256 public smartPoolAssets;
  uint256 public smartPoolAssetsAverage;

  uint256 public totalFlexibleBorrowsShares;
  uint256 public lastUpdatedSmartPoolRate;
  uint256 public spPreviousUtilization;

  address public treasury;
  uint128 public treasuryFee;

  event Borrow(
    address indexed caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 shares
  );

  event Repay(address indexed caller, address indexed borrower, uint256 assets, uint256 shares);

  /// @notice Event emitted when a user deposits an amount of an asset to a certain fixed rate pool collecting a fee at
  /// the end of the period.
  /// @param maturity maturity at which the user will be able to collect his deposit + his fee.
  /// @param caller address which deposited the assets.
  /// @param owner address that will be able to withdraw the deposited assets.
  /// @param assets amount of the asset that were deposited.
  /// @param fee is the extra amount that it will be collected at maturity.
  event DepositAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed owner,
    uint256 assets,
    uint256 fee
  );

  /// @notice Event emitted when a user withdraws from a fixed rate pool.
  /// @param maturity maturity where the user withdraw its deposits.
  /// @param caller address which withdraw the asset.
  /// @param receiver address which will be collecting the assets.
  /// @param owner address which had the assets withdrawn.
  /// @param assets amount of the asset that were withdrawn.
  /// @param assetsDiscounted amount of the asset that were deposited (in case of early withdrawal).
  event WithdrawAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 assetsDiscounted
  );

  /// @notice Event emitted when a user borrows amount of an asset from a certain maturity date.
  /// @param maturity maturity in which the user will have to repay the loan.
  /// @param caller address which borrowed the asset.
  /// @param receiver address that received the borrowed assets.
  /// @param borrower address which will be repaying the borrowed assets.
  /// @param assets amount of the asset that were borrowed.
  /// @param fee extra amount that will need to be paid at maturity.
  event BorrowAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 fee
  );

  /// @notice Event emitted when a user repays its borrows after maturity.
  /// @param maturity maturity where the user repaid its borrowed amounts.
  /// @param caller address which repaid the previously borrowed amount.
  /// @param borrower address which had the original debt.
  /// @param assets amount that was repaid.
  /// @param positionAssets amount of the debt that was covered in this repayment (penalties could have been repaid).
  event RepayAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed borrower,
    uint256 assets,
    uint256 positionAssets
  );

  /// @notice Event emitted when a user's position had a liquidation.
  /// @param receiver address which repaid the previously borrowed amount.
  /// @param borrower address which had the original debt.
  /// @param assets amount of the asset that were repaid.
  /// @param lendersAssets incentive paid to lenders.
  /// @param collateralMarket address of the asset that were seized by the liquidator.
  /// @param seizedAssets amount seized of the collateral.
  event LiquidateBorrow(
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 lendersAssets,
    FixedLender indexed collateralMarket,
    uint256 seizedAssets
  );

  /// @notice Event emitted when a user's collateral has been seized.
  /// @param liquidator address which seized this collateral.
  /// @param borrower address which had the original debt.
  /// @param assets amount seized of the collateral.
  event AssetSeized(address indexed liquidator, address indexed borrower, uint256 assets);

  /// @notice Event emitted when earnings are accrued to the smart pool.
  /// @param previousAssets previous balance of the smart pool, denominated in assets (underlying).
  /// @param earnings new smart pool earnings, denominated in assets (underlying).
  event SmartPoolEarningsAccrued(uint256 previousAssets, uint256 earnings);

  /// @notice Event emitted when the accumulatedEarningsSmoothFactor is changed by admin.
  /// @param newAccumulatedEarningsSmoothFactor factor represented with 1e18 decimals.
  event AccumulatedEarningsSmoothFactorSet(uint128 newAccumulatedEarningsSmoothFactor);

  /// @notice Event emitted when the maxFuturePools is changed by admin.
  /// @param newMaxFuturePools represented with 0 decimals.
  event MaxFuturePoolsSet(uint256 newMaxFuturePools);

  /// @notice emitted when the interestRateModel is changed by admin.
  /// @param newInterestRateModel new interest rate model to be used to calculate rates.
  event InterestRateModelSet(InterestRateModel indexed newInterestRateModel);

  /// @notice emitted when the penaltyRate is changed by admin.
  /// @param newPenaltyRate penaltyRate percentage per second represented with 1e18 decimals.
  event PenaltyRateSet(uint256 newPenaltyRate);

  /// @notice Emitted when the smartPoolFeeRate parameter is changed by admin.
  /// @param smartPoolFeeRate rate charged to the mp suppliers to be accrued by the sp suppliers.
  event SmartPoolFeeRateSet(uint256 smartPoolFeeRate);

  /// @notice emitted when the smartPoolReserveFactor is changed by admin.
  /// @param newSmartPoolReserveFactor smartPoolReserveFactor percentage.
  event SmartPoolReserveFactorSet(uint128 newSmartPoolReserveFactor);

  /// @notice emitted when the damp speeds are changed by admin.
  /// @param newDampSpeedUp represented with 1e18 decimals.
  /// @param newDampSpeedDown represented with 1e18 decimals.
  event DampSpeedSet(uint256 newDampSpeedUp, uint256 newDampSpeedDown);

  /// @notice emitted when the treasury variables are changed by admin.
  /// @param treasury address of the treasury that will receive the minted eTokens.
  /// @param treasuryFee represented with 1e18 decimals.
  event TreasurySet(address treasury, uint128 treasuryFee);

  event MarketUpdated(
    uint256 timestamp,
    uint256 smartPoolShares,
    uint256 smartPoolAssets,
    uint256 smartPoolEarningsAccumulator,
    uint256 indexed maturity,
    uint256 maturityUnassignedEarnings
  );

  constructor(
    ERC20 asset_,
    uint8 maxFuturePools_,
    uint128 accumulatedEarningsSmoothFactor_,
    Auditor auditor_,
    InterestRateModel interestRateModel_,
    uint256 penaltyRate_,
    uint256 smartPoolFeeRate_,
    uint128 smartPoolReserveFactor_,
    DampSpeed memory dampSpeed_
  )
    ERC4626(asset_, string(abi.encodePacked("EToken", asset_.symbol())), string(abi.encodePacked("e", asset_.symbol())))
  {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    auditor = auditor_;
    setMaxFuturePools(maxFuturePools_);
    setAccumulatedEarningsSmoothFactor(accumulatedEarningsSmoothFactor_);
    setInterestRateModel(interestRateModel_);
    setPenaltyRate(penaltyRate_);
    setSmartPoolFeeRate(smartPoolFeeRate_);
    setSmartPoolReserveFactor(smartPoolReserveFactor_);
    setDampSpeed(dampSpeed_);
  }

  /// @notice Calculates the smart pool balance plus earnings to be accrued at current timestamp
  /// from maturities and accumulator.
  /// @return actual smartPoolAssets plus earnings to be accrued at current timestamp.
  function totalAssets() public view override returns (uint256) {
    unchecked {
      uint256 memMaxFuturePools = maxFuturePools;
      uint256 smartPoolEarnings = 0;

      uint256 lastAccrual;
      uint256 unassignedEarnings;
      uint256 latestMaturity = block.timestamp - (block.timestamp % TSUtils.INTERVAL);
      uint256 maxMaturity = latestMaturity + memMaxFuturePools * TSUtils.INTERVAL;

      assembly {
        mstore(0x20, fixedPools.slot) // hashing scratch space, second word for storage location hashing
      }

      for (uint256 maturity = latestMaturity; maturity <= maxMaturity; maturity += TSUtils.INTERVAL) {
        assembly {
          mstore(0x00, maturity) // hashing scratch space, first word for storage location hashing
          let location := keccak256(0x00, 0x40) // struct storage location: keccak256([maturity, fixedPools.slot])
          unassignedEarnings := sload(add(location, 2)) // third word
          lastAccrual := sload(add(location, 3)) // forth word
        }

        if (maturity > lastAccrual) {
          smartPoolEarnings += unassignedEarnings.mulDivDown(block.timestamp - lastAccrual, maturity - lastAccrual);
        }
      }

      return smartPoolAssets + smartPoolEarnings + smartPoolAccumulatedEarnings();
    }
  }

  /// @notice Withdraws the owner's smart pool assets to the receiver address.
  /// @dev Makes sure that the owner doesn't have shortfall after withdrawing.
  /// @param assets amount of underlying to be withdrawn.
  /// @param receiver address to which the assets will be transferred.
  /// @param owner address which owns the smart pool assets.
  function withdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public override returns (uint256 shares) {
    auditor.validateAccountShortfall(this, owner, assets);
    shares = super.withdraw(assets, receiver, owner);
    emit MarketUpdated(block.timestamp, totalSupply, smartPoolAssets, smartPoolEarningsAccumulator, 0, 0);
  }

  /// @notice Redeems the owner's smart pool assets to the receiver address.
  /// @dev Makes sure that the owner doesn't have shortfall after withdrawing.
  /// @param shares amount of shares to be redeemed for underlying asset.
  /// @param receiver address to which the assets will be transferred.
  /// @param owner address which owns the smart pool assets.
  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) public override returns (uint256 assets) {
    auditor.validateAccountShortfall(this, owner, previewMint(shares));
    assets = super.redeem(shares, receiver, owner);
    emit MarketUpdated(block.timestamp, totalSupply, smartPoolAssets, smartPoolEarningsAccumulator, 0, 0);
  }

  /// @notice Hook to update the smart pool average, smart pool balance and distribute earnings from accumulator.
  /// @param assets amount of assets to be withdrawn from the smart pool.
  function beforeWithdraw(uint256 assets, uint256) internal override {
    updateSmartPoolFlexibleBorrows();
    updateSmartPoolAssetsAverage();
    uint256 earnings = smartPoolAccumulatedEarnings();
    lastAccumulatedEarningsAccrual = uint32(block.timestamp);
    smartPoolEarningsAccumulator -= earnings;
    uint256 memSPAssets = smartPoolAssets;
    emit SmartPoolEarningsAccrued(memSPAssets, earnings);
    memSPAssets = memSPAssets + earnings - assets;
    smartPoolAssets = memSPAssets;
    // we check if the underlying liquidity that the user wants to withdraw is borrowed
    if (memSPAssets < smartPoolFixedBorrows + smartPoolFlexibleBorrows) revert InsufficientProtocolLiquidity();
  }

  /// @notice Hook to update the smart pool average, smart pool balance and distribute earnings from accumulator.
  /// @param assets amount of assets to be deposited to the smart pool.
  function afterDeposit(uint256 assets, uint256) internal virtual override whenNotPaused {
    updateSmartPoolFlexibleBorrows();
    updateSmartPoolAssetsAverage();
    uint256 memSPAssets = smartPoolAssets;
    uint256 earnings = smartPoolAccumulatedEarnings();
    lastAccumulatedEarningsAccrual = uint32(block.timestamp);
    smartPoolEarningsAccumulator -= earnings;
    emit SmartPoolEarningsAccrued(memSPAssets, earnings);
    smartPoolAssets = memSPAssets + earnings + assets;
    emit MarketUpdated(block.timestamp, totalSupply, smartPoolAssets, smartPoolEarningsAccumulator, 0, 0);
  }

  /// @notice Calculates the earnings to be distributed from the accumulator given the current timestamp.
  /// @return earnings to be distributed from the accumulator.
  function smartPoolAccumulatedEarnings() internal view returns (uint256 earnings) {
    uint256 elapsed = block.timestamp - lastAccumulatedEarningsAccrual;
    if (elapsed == 0) return 0;
    earnings = smartPoolEarningsAccumulator.mulDivDown(
      elapsed,
      elapsed + accumulatedEarningsSmoothFactor.mulWadDown(maxFuturePools * TSUtils.INTERVAL)
    );
  }

  /// @notice Moves amount of shares from the caller's account to `to`.
  /// @dev It's expected that this function can't be paused to prevent freezing user funds.
  /// Makes sure that the caller doesn't have shortfall after transferring.
  /// @param to address to which the tokens will be transferred.
  /// @param shares amount of tokens.
  function transfer(address to, uint256 shares) public override returns (bool) {
    auditor.validateAccountShortfall(this, msg.sender, previewMint(shares));
    return super.transfer(to, shares);
  }

  /// @notice Moves amount of shares from `from` to `to` using the allowance mechanism.
  /// @dev It's expected that this function can't be paused to prevent freezing user funds.
  /// Makes sure that `from` address doesn't have shortfall after transferring.
  /// @param from address from which the tokens will be transferred.
  /// @param to address to which the tokens will be transferred.
  /// @param shares amount of tokens.
  function transferFrom(
    address from,
    address to,
    uint256 shares
  ) public override returns (bool) {
    auditor.validateAccountShortfall(this, from, previewMint(shares));
    return super.transferFrom(from, to, shares);
  }

  /// @notice Sets the protocol's max future pools for borrowing and lending.
  /// @dev Value can not be 0 or higher than 224.
  /// Value shouldn't be lower than previous value or VALID maturities will become NOT_READY.
  /// @param futurePools number of pools to be active at the same time.
  function setMaxFuturePools(uint8 futurePools) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (futurePools > 224 || futurePools == 0) revert InvalidParameter();
    maxFuturePools = futurePools;
    emit MaxFuturePoolsSet(futurePools);
  }

  /// @notice Sets the treasury variables.
  /// @param treasury_ address of the treasury that will receive the minted eTokens.
  /// @param treasuryFee_ represented with 1e18 decimals.
  function setTreasury(address treasury_, uint128 treasuryFee_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (treasuryFee_ > 1e17) revert InvalidParameter();
    treasury = treasury_;
    treasuryFee = treasuryFee_;
    emit TreasurySet(treasury_, treasuryFee_);
  }

  /// @notice Sets the factor used when smoothly accruing earnings to the smart pool.
  /// @dev Value can only be lower than 4. If set at 0, then all remaining accumulated earnings are
  /// distributed in following operation to the smart pool.
  /// @param accumulatedEarningsSmoothFactor_ represented with 18 decimals.
  function setAccumulatedEarningsSmoothFactor(uint128 accumulatedEarningsSmoothFactor_)
    public
    onlyRole(DEFAULT_ADMIN_ROLE)
  {
    if (accumulatedEarningsSmoothFactor_ > 4e18) revert InvalidParameter();
    accumulatedEarningsSmoothFactor = accumulatedEarningsSmoothFactor_;
    emit AccumulatedEarningsSmoothFactorSet(accumulatedEarningsSmoothFactor_);
  }

  /// @notice Sets the interest rate model to be used to calculate rates.
  /// @param interestRateModel_ new interest rate model.
  function setInterestRateModel(InterestRateModel interestRateModel_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    interestRateModel = interestRateModel_;
    emit InterestRateModelSet(interestRateModel_);
  }

  /// @notice Sets the penalty rate per second.
  /// @dev Value can only be set approximately between 5% and 1% daily.
  /// @param penaltyRate_ percentage represented with 18 decimals.
  function setPenaltyRate(uint256 penaltyRate_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (penaltyRate_ > 5.79e11 || penaltyRate_ < 1.15e11) revert InvalidParameter();
    penaltyRate = penaltyRate_;
    emit PenaltyRateSet(penaltyRate_);
  }

  /// @notice Sets the rate charged to the mp depositors that the sp suppliers will retain for initially providing
  /// liquidity.
  /// @dev Value can only be set between 20% and 0%.
  /// @param smartPoolFeeRate_ percentage amount represented with 1e18 decimals.
  function setSmartPoolFeeRate(uint256 smartPoolFeeRate_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (smartPoolFeeRate_ > 0.2e18) revert InvalidParameter();
    smartPoolFeeRate = smartPoolFeeRate_;
    emit SmartPoolFeeRateSet(smartPoolFeeRate_);
  }

  /// @notice Sets the percentage that represents the smart pool liquidity reserves that can't be borrowed.
  /// @dev Value can only be set between 20% and 0%.
  /// @param smartPoolReserveFactor_ parameter represented with 18 decimals.
  function setSmartPoolReserveFactor(uint128 smartPoolReserveFactor_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (smartPoolReserveFactor_ > 0.2e18) revert InvalidParameter();
    smartPoolReserveFactor = smartPoolReserveFactor_;
    emit SmartPoolReserveFactorSet(smartPoolReserveFactor_);
  }

  /// @notice Sets the damp speed used to update the smartPoolAssetsAverage.
  /// @dev Values can only be set between 0 and 100%.
  /// @param dampSpeed represented with 18 decimals.
  function setDampSpeed(DampSpeed memory dampSpeed) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (dampSpeed.up > 1e18 || dampSpeed.down > 1e18) revert InvalidParameter();
    dampSpeedUp = dampSpeed.up;
    dampSpeedDown = dampSpeed.down;
    emit DampSpeedSet(dampSpeed.up, dampSpeed.down);
  }

  /// @notice Sets the _pause state to true in case of emergency, triggered by an authorized account.
  function pause() external onlyRole(PAUSER_ROLE) {
    _pause();
  }

  /// @notice Sets the _pause state to false when threat is gone, triggered by an authorized account.
  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  /// @notice Liquidates undercollateralized position(s).
  /// @dev Msg.sender liquidates borrower's position(s) and repays a certain amount of debt for multiple maturities,
  /// seizing a part of borrower's collateral.
  /// @param borrower wallet that has an outstanding debt across all maturities.
  /// @param maxAssets maximum amount of debt that the liquidator is willing to accept. (it can be less)
  /// @param collateralMarket fixedLender from which the collateral will be seized to give the liquidator.
  function liquidate(
    address borrower,
    uint256 maxAssets,
    FixedLender collateralMarket
  ) external nonReentrant whenNotPaused returns (uint256 repaidAssets) {
    if (msg.sender == borrower) revert SelfLiquidation();

    bool moreCollateral;
    (maxAssets, moreCollateral) = auditor.checkLiquidation(this, collateralMarket, borrower, maxAssets);
    if (maxAssets == 0) revert ZeroRepay();

    uint256 packedMaturities = fixedBorrows[borrower];
    uint256 baseMaturity = packedMaturities % (1 << 32);
    packedMaturities = packedMaturities >> 32;

    uint256 i = 0;
    for (; i < 224; ) {
      if ((packedMaturities & (1 << i)) != 0) {
        uint256 maturity = baseMaturity + (i * TSUtils.INTERVAL);
        uint256 actualRepay;
        if (block.timestamp < maturity) {
          actualRepay = noTransferRepayAtMaturity(maturity, maxAssets, maxAssets, borrower, false);
          maxAssets -= actualRepay;
        } else {
          uint256 position;
          {
            PoolLib.Position memory p = fixedBorrowPositions[maturity][borrower];
            position = p.principal + p.fee;
          }
          uint256 debt = position + position.mulWadDown((block.timestamp - maturity) * penaltyRate);
          actualRepay = debt > maxAssets ? maxAssets.mulDivDown(position, debt) : maxAssets;

          if (actualRepay == 0) maxAssets = 0;
          else {
            actualRepay = noTransferRepayAtMaturity(maturity, actualRepay, maxAssets, borrower, false);
            maxAssets -= actualRepay;
            {
              PoolLib.Position memory p = fixedBorrowPositions[maturity][borrower];
              position = p.principal + p.fee;
            }
            debt = position + position.mulWadDown((block.timestamp - maturity) * penaltyRate);
            if ((debt > maxAssets ? maxAssets.mulDivDown(position, debt) : maxAssets) == 0) maxAssets = 0;
          }
        }
        repaidAssets += actualRepay;
      }

      unchecked {
        ++i;
      }
      if ((1 << i) > packedMaturities || maxAssets == 0) break;
    }

    if (maxAssets > 0 && flexibleBorrowPositions[borrower] > 0) {
      uint256 actualRepayAssets = noTransferRepay(
        maxAssets.mulDivDown(totalFlexibleBorrowsShares, floatingBorrowAssets()),
        borrower
      );
      repaidAssets += actualRepayAssets;
      maxAssets -= actualRepayAssets;
    }

    uint256 lendersAssets;
    // reverts on failure
    (maxAssets, lendersAssets) = auditor.liquidateCalculateSeizeAmount(this, collateralMarket, borrower, repaidAssets);

    moreCollateral =
      (
        // if this is also the collateral run `_seize` to avoid re-entrancy, otherwise make an external call.
        // both revert on failure
        address(collateralMarket) == address(this)
          ? _seize(this, msg.sender, borrower, maxAssets)
          : collateralMarket.seize(msg.sender, borrower, maxAssets)
      ) ||
      moreCollateral;

    emit LiquidateBorrow(msg.sender, borrower, repaidAssets, lendersAssets, collateralMarket, maxAssets);

    asset.safeTransferFrom(msg.sender, address(this), repaidAssets + lendersAssets);

    if (!moreCollateral) {
      for (--i; i < 224; ) {
        if ((packedMaturities & (1 << i)) != 0) {
          uint256 maturity = baseMaturity + (i * TSUtils.INTERVAL);

          PoolLib.Position memory position = fixedBorrowPositions[maturity][borrower];
          uint256 badDebt = position.principal + position.fee;
          if (badDebt > 0) {
            smartPoolFixedBorrows -= fixedPools[maturity].repay(position.principal);
            spreadBadDebt(badDebt);
            delete fixedBorrowPositions[maturity][borrower];
            fixedBorrows[borrower] = fixedBorrows[borrower].clearMaturity(maturity);

            emit RepayAtMaturity(maturity, msg.sender, borrower, badDebt, badDebt);
            emit MarketUpdated(
              block.timestamp,
              totalSupply,
              smartPoolAssets,
              smartPoolEarningsAccumulator,
              maturity,
              fixedPools[maturity].earningsUnassigned
            );
          }
        }

        unchecked {
          ++i;
        }
        if ((1 << i) > packedMaturities) break;
      }
      uint256 borrowShares = flexibleBorrowPositions[borrower];
      if (borrowShares > 0) {
        uint256 badDebt = noTransferRepay(borrowShares, borrower);
        spreadBadDebt(badDebt);
        emit MarketUpdated(
          block.timestamp,
          totalSupply,
          smartPoolAssets,
          smartPoolEarningsAccumulator,
          type(uint256).max,
          0
        );
      }
    }
  }

  /// @notice Public function to seize a certain amount of tokens.
  /// @dev Public function for liquidator to seize borrowers tokens in the smart pool.
  /// This function will only be called from another FixedLender, on `liquidation` calls.
  /// That's why msg.sender needs to be passed to the private function (to be validated as a market)
  /// @param liquidator address which will receive the seized tokens.
  /// @param borrower address from which the tokens will be seized.
  /// @param assets amount to be removed from borrower's possession.
  function seize(
    address liquidator,
    address borrower,
    uint256 assets
  ) external nonReentrant whenNotPaused returns (bool moreCollateral) {
    moreCollateral = _seize(FixedLender(msg.sender), liquidator, borrower, assets);
    emit MarketUpdated(block.timestamp, totalSupply, smartPoolAssets, smartPoolEarningsAccumulator, 0, 0);
  }

  /// @notice Borrows a certain amount from a maturity.
  /// @param maturity maturity date for repayment.
  /// @param assets amount to be sent to receiver and repaid by borrower.
  /// @param maxAssets maximum amount of debt that the user is willing to accept.
  /// @param receiver address that will receive the borrowed assets.
  /// @param borrower address that will repay the borrowed assets.
  function borrowAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 maxAssets,
    address receiver,
    address borrower
  ) public nonReentrant whenNotPaused returns (uint256 assetsOwed) {
    // reverts on failure
    TSUtils.validateRequiredPoolState(maxFuturePools, maturity, TSUtils.State.VALID, TSUtils.State.NONE);

    PoolLib.FixedPool storage pool = fixedPools[maturity];

    uint256 earningsSP = pool.accrueEarnings(maturity, block.timestamp);

    updateSmartPoolAssetsAverage();
    uint256 fee = assets.mulWadDown(
      interestRateModel.getFixedBorrowRate(
        maturity,
        block.timestamp,
        assets,
        pool.borrowed,
        pool.supplied,
        smartPoolAssetsAverage
      )
    );
    assetsOwed = assets + fee;

    {
      uint256 memSPFixedBorrows = smartPoolFixedBorrows;
      memSPFixedBorrows += pool.borrow(assets, smartPoolAssets - memSPFixedBorrows - smartPoolFlexibleBorrows);
      smartPoolFixedBorrows = memSPFixedBorrows;
      checkSmartPoolReserveExceeded();
    }

    // We validate that the user is not taking arbitrary fees
    if (assetsOwed > maxAssets) revert TooMuchSlippage();

    if (msg.sender != borrower) {
      uint256 allowed = allowance[borrower][msg.sender]; // saves gas for limited approvals.

      if (allowed != type(uint256).max) allowance[borrower][msg.sender] = allowed - previewWithdraw(assetsOwed);
    }

    // If user doesn't have a current position, we add it to the list of all of them
    PoolLib.Position memory position = fixedBorrowPositions[maturity][borrower];
    if (position.principal == 0) {
      fixedBorrows[borrower] = fixedBorrows[borrower].setMaturity(maturity);
    }

    // We calculate what portion of the fees are to be accrued and what portion goes to earnings accumulator
    (uint256 newUnassignedEarnings, uint256 newEarningsSP) = PoolLib.distributeEarningsAccordingly(
      chargeTreasuryFee(fee),
      pool.smartPoolBorrowed(),
      assets
    );
    pool.earningsUnassigned += newUnassignedEarnings;
    collectFreeLunch(newEarningsSP);

    fixedBorrowPositions[maturity][borrower] = PoolLib.Position(position.principal + assets, position.fee + fee);

    {
      uint256 memSPAssets = smartPoolAssets;
      emit SmartPoolEarningsAccrued(memSPAssets, earningsSP);
      smartPoolAssets = memSPAssets + earningsSP;
    }

    auditor.validateBorrow(this, borrower);
    asset.safeTransfer(receiver, assets);

    emit BorrowAtMaturity(maturity, msg.sender, receiver, borrower, assets, fee);
    emit MarketUpdated(
      block.timestamp,
      totalSupply,
      smartPoolAssets,
      smartPoolEarningsAccumulator,
      maturity,
      pool.earningsUnassigned
    );
  }

  /// @notice Deposits a certain amount to a maturity.
  /// @param maturity maturity date / pool ID.
  /// @param assets amount to receive from the msg.sender.
  /// @param minAssetsRequired minimum amount of assets required by the depositor for the transaction to be accepted.
  /// @param receiver address that will be able to withdraw the deposited assets.
  /// @return positionAssets total amount of assets (principal + fee) to be withdrawn at maturity.
  function depositAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired,
    address receiver
  ) public nonReentrant whenNotPaused returns (uint256 positionAssets) {
    // reverts on failure
    TSUtils.validateRequiredPoolState(maxFuturePools, maturity, TSUtils.State.VALID, TSUtils.State.NONE);

    PoolLib.FixedPool storage pool = fixedPools[maturity];

    uint256 earningsSP = pool.accrueEarnings(maturity, block.timestamp);

    (uint256 fee, uint256 feeSP) = assets.getDepositYield(
      pool.earningsUnassigned,
      pool.smartPoolBorrowed(),
      smartPoolFeeRate
    );
    positionAssets = assets + fee;
    if (positionAssets < minAssetsRequired) revert TooMuchSlippage();

    smartPoolFixedBorrows -= pool.deposit(assets);
    pool.earningsUnassigned -= fee + feeSP;
    smartPoolEarningsAccumulator += feeSP;

    // We update user's position
    PoolLib.Position memory position = fixedDepositPositions[maturity][receiver];

    // If user doesn't have a current position, we add it to the list of all of them
    if (position.principal == 0) {
      fixedDeposits[receiver] = fixedDeposits[receiver].setMaturity(maturity);
    }

    fixedDepositPositions[maturity][receiver] = PoolLib.Position(position.principal + assets, position.fee + fee);

    uint256 memSPAssets = smartPoolAssets;
    emit SmartPoolEarningsAccrued(memSPAssets, earningsSP);
    smartPoolAssets = memSPAssets + earningsSP;

    emit DepositAtMaturity(maturity, msg.sender, receiver, assets, fee);
    emit MarketUpdated(
      block.timestamp,
      totalSupply,
      smartPoolAssets,
      smartPoolEarningsAccumulator,
      maturity,
      pool.earningsUnassigned
    );

    asset.safeTransferFrom(msg.sender, address(this), assets);
  }

  /// @notice Withdraws a certain amount from a maturity.
  /// @dev It's expected that this function can't be paused to prevent freezing user funds.
  /// @param maturity maturity date where the assets will be withdrawn.
  /// @param positionAssets the amount of assets (principal + fee) to be withdrawn.
  /// @param minAssetsRequired minimum amount required by the user (if discount included for early withdrawal).
  /// @param receiver address that will receive the withdrawn assets.
  /// @param owner address that previously deposited the assets.
  /// @return assetsDiscounted amount of assets withdrawn (can include a discount for early withdraw).
  function withdrawAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 minAssetsRequired,
    address receiver,
    address owner
  ) public nonReentrant returns (uint256 assetsDiscounted) {
    if (positionAssets == 0) revert ZeroWithdraw();
    // reverts on failure
    TSUtils.validateRequiredPoolState(maxFuturePools, maturity, TSUtils.State.VALID, TSUtils.State.MATURED);

    PoolLib.FixedPool storage pool = fixedPools[maturity];

    uint256 earningsSP = pool.accrueEarnings(maturity, block.timestamp);

    PoolLib.Position memory position = fixedDepositPositions[maturity][owner];

    if (positionAssets > position.principal + position.fee) positionAssets = position.principal + position.fee;

    // We verify if there are any penalties/fee for him because of
    // early withdrawal - if so: discount
    if (block.timestamp < maturity) {
      updateSmartPoolAssetsAverage();
      assetsDiscounted = positionAssets.divWadDown(
        1e18 +
          interestRateModel.getFixedBorrowRate(
            maturity,
            block.timestamp,
            positionAssets,
            pool.borrowed,
            pool.supplied,
            smartPoolAssetsAverage
          )
      );
    } else {
      assetsDiscounted = positionAssets;
    }

    if (assetsDiscounted < minAssetsRequired) revert TooMuchSlippage();

    if (msg.sender != owner) {
      uint256 allowed = allowance[owner][msg.sender]; // saves gas for limited approvals.

      if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - previewWithdraw(assetsDiscounted);
    }

    // We remove the supply from the fixed rate pool
    smartPoolFixedBorrows += pool.withdraw(
      PoolLib.Position(position.principal, position.fee).scaleProportionally(positionAssets).principal,
      smartPoolAssets - smartPoolFixedBorrows - smartPoolFlexibleBorrows
    );

    // All the fees go to unassigned or to the smart pool
    (uint256 earningsUnassigned, uint256 newEarningsSP) = PoolLib.distributeEarningsAccordingly(
      chargeTreasuryFee(positionAssets - assetsDiscounted),
      pool.smartPoolBorrowed(),
      assetsDiscounted
    );
    pool.earningsUnassigned += earningsUnassigned;
    collectFreeLunch(newEarningsSP);

    // the user gets discounted the full amount
    position.reduceProportionally(positionAssets);
    if (position.principal + position.fee == 0) {
      delete fixedDepositPositions[maturity][owner];
      fixedDeposits[owner] = fixedDeposits[owner].clearMaturity(maturity);
    } else {
      // we proportionally reduce the values
      fixedDepositPositions[maturity][owner] = position;
    }

    uint256 memSPAssets = smartPoolAssets;
    emit SmartPoolEarningsAccrued(memSPAssets, earningsSP);
    smartPoolAssets = memSPAssets + earningsSP;

    asset.safeTransfer(receiver, assetsDiscounted);

    emit WithdrawAtMaturity(maturity, msg.sender, receiver, owner, positionAssets, assetsDiscounted);
    emit MarketUpdated(
      block.timestamp,
      totalSupply,
      smartPoolAssets,
      smartPoolEarningsAccumulator,
      maturity,
      pool.earningsUnassigned
    );
  }

  /// @notice Repays a certain amount to a maturity.
  /// @param maturity maturity date where the assets will be repaid.
  /// @param positionAssets amount to be paid for the borrower's debt.
  /// @param maxAssets maximum amount of debt that the user is willing to accept to be repaid.
  /// @param borrower address of the account that has the debt.
  /// @return actualRepayAssets the actual amount that was transferred into the protocol.
  function repayAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 maxAssets,
    address borrower
  ) public nonReentrant whenNotPaused returns (uint256 actualRepayAssets) {
    // reverts on failure
    TSUtils.validateRequiredPoolState(maxFuturePools, maturity, TSUtils.State.VALID, TSUtils.State.MATURED);

    actualRepayAssets = noTransferRepayAtMaturity(maturity, positionAssets, maxAssets, borrower, true);
    asset.safeTransferFrom(msg.sender, address(this), actualRepayAssets);
  }

  /// @notice This function allows to (partially) repay a position. It does not transfer tokens.
  /// @dev Internal repay function, allows partial repayment.
  /// @param maturity the maturity to access the pool.
  /// @param positionAssets the amount of debt of the pool that should be paid.
  /// @param maxAssets maximum amount of debt that the user is willing to accept to be repaid.
  /// @param borrower the address of the account that has the debt.
  /// @return actualRepayAssets the actual amount that should be transferred into the protocol.
  function noTransferRepayAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 maxAssets,
    address borrower,
    bool canDiscount
  ) internal returns (uint256 actualRepayAssets) {
    if (positionAssets == 0) revert ZeroRepay();

    PoolLib.FixedPool storage pool = fixedPools[maturity];

    uint256 earningsSP = pool.accrueEarnings(maturity, block.timestamp);

    PoolLib.Position memory position = fixedBorrowPositions[maturity][borrower];

    uint256 debtCovered = Math.min(positionAssets, position.principal + position.fee);

    PoolLib.Position memory scaleDebtCovered = PoolLib.Position(position.principal, position.fee).scaleProportionally(
      debtCovered
    );

    // Early repayment allows you to get a discount from the unassigned earnings
    if (block.timestamp < maturity) {
      if (canDiscount) {
        // We calculate the deposit fee considering the amount of debt the user'll pay
        (uint256 discountFee, uint256 feeSP) = scaleDebtCovered.principal.getDepositYield(
          pool.earningsUnassigned,
          pool.smartPoolBorrowed(),
          smartPoolFeeRate
        );

        // We remove the fee from unassigned earnings
        pool.earningsUnassigned -= discountFee + feeSP;

        // The fee charged to the MP supplier go to the smart pool accumulator
        smartPoolEarningsAccumulator += feeSP;

        // The fee gets discounted from the user through `repayAmount`
        actualRepayAssets = debtCovered - discountFee;
      } else {
        actualRepayAssets = debtCovered;
      }
    } else {
      actualRepayAssets = debtCovered + debtCovered.mulWadDown((block.timestamp - maturity) * penaltyRate);

      // All penalties go to the smart pool accumulator
      smartPoolEarningsAccumulator += actualRepayAssets - debtCovered;
    }

    // We verify that the user agrees to this discount or penalty
    if (actualRepayAssets > maxAssets) revert TooMuchSlippage();

    // We reduce the borrowed and we might decrease the SP debt
    smartPoolFixedBorrows -= pool.repay(scaleDebtCovered.principal);

    // We update the user position
    position.reduceProportionally(debtCovered);
    if (position.principal + position.fee == 0) {
      delete fixedBorrowPositions[maturity][borrower];
      fixedBorrows[borrower] = fixedBorrows[borrower].clearMaturity(maturity);
    } else {
      // We proportionally reduce the values
      fixedBorrowPositions[maturity][borrower] = position;
    }

    uint256 memSPAssets = smartPoolAssets;
    emit SmartPoolEarningsAccrued(memSPAssets, earningsSP);
    smartPoolAssets = memSPAssets + earningsSP;

    emit RepayAtMaturity(maturity, msg.sender, borrower, actualRepayAssets, debtCovered);
    emit MarketUpdated(
      block.timestamp,
      totalSupply,
      smartPoolAssets,
      smartPoolEarningsAccumulator,
      maturity,
      pool.earningsUnassigned
    );
  }

  /// @notice Internal function to seize a certain amount of tokens.
  /// @dev Internal function for liquidator to seize borrowers tokens in the smart pool.
  /// Will only be called from this FixedLender on `liquidation` or through `seize` calls from another FixedLender.
  /// That's why msg.sender needs to be passed to the internal function (to be validated as a market).
  /// @param seizerFixedLender address which is calling the seize function (see `seize` public function).
  /// @param liquidator address which will receive the seized tokens.
  /// @param borrower address from which the tokens will be seized.
  /// @param assets amount to be removed from borrower's possession.
  function _seize(
    FixedLender seizerFixedLender,
    address liquidator,
    address borrower,
    uint256 assets
  ) internal returns (bool moreCollateral) {
    if (assets == 0) revert ZeroWithdraw();

    // reverts on failure
    auditor.checkSeize(this, seizerFixedLender);

    uint256 shares = previewWithdraw(assets);
    beforeWithdraw(assets, shares);
    _burn(borrower, shares);
    emit Withdraw(msg.sender, liquidator, borrower, assets, shares);

    asset.safeTransfer(liquidator, assets);
    emit AssetSeized(liquidator, borrower, assets);
    emit MarketUpdated(block.timestamp, totalSupply, smartPoolAssets, smartPoolEarningsAccumulator, 0, 0);

    return balanceOf[borrower] > 0;
  }

  /// @notice Gets current snapshot for an account across all maturities.
  /// @param account account to return status snapshot in the specified maturity date.
  /// @return the amount the user deposited to the smart pool and the total money he owes from maturities.
  function getAccountSnapshot(address account) external view returns (uint256, uint256) {
    return (convertToAssets(balanceOf[account]), getDebt(account));
  }

  /// @notice Gets all borrows and penalties for an account.
  /// @param account account to return status snapshot for fixed and flexible borrows.
  /// @return debt the total debt, denominated in number of tokens.
  function getDebt(address account) public view returns (uint256 debt) {
    uint256 memPenaltyRate = penaltyRate;
    uint256 packedMaturities = fixedBorrows[account];
    uint256 baseMaturity = packedMaturities % (1 << 32);
    packedMaturities = packedMaturities >> 32;
    // calculate all maturities using the baseMaturity and the following bits representing the following intervals
    for (uint256 i = 0; i < 224; ) {
      if ((packedMaturities & (1 << i)) != 0) {
        uint256 maturity = baseMaturity + (i * TSUtils.INTERVAL);
        PoolLib.Position memory position = fixedBorrowPositions[maturity][account];
        uint256 positionAssets = position.principal + position.fee;

        debt += positionAssets;

        uint256 secondsDelayed = TSUtils.secondsPre(maturity, block.timestamp);
        if (secondsDelayed > 0) debt += positionAssets.mulWadDown(secondsDelayed * memPenaltyRate);
      }

      unchecked {
        ++i;
      }
      if ((1 << i) > packedMaturities) break;
    }
    // calculate flexible borrowed debt
    uint256 shares = flexibleBorrowPositions[account];
    if (shares > 0) debt += previewRepay(shares);
  }

  /// @notice Updates the smartPoolAssetsAverage.
  function updateSmartPoolAssetsAverage() internal {
    uint256 memSmartPoolAssets = smartPoolAssets;
    uint256 memSmartPoolAssetsAverage = smartPoolAssetsAverage;
    uint256 dampSpeedFactor = memSmartPoolAssets < memSmartPoolAssetsAverage ? dampSpeedDown : dampSpeedUp;
    uint256 averageFactor = uint256(1e18 - (-int256(dampSpeedFactor * (block.timestamp - lastAverageUpdate))).expWad());
    smartPoolAssetsAverage =
      memSmartPoolAssetsAverage.mulWadDown(1e18 - averageFactor) +
      averageFactor.mulWadDown(memSmartPoolAssets);
    lastAverageUpdate = uint32(block.timestamp);
  }

  /// @notice Checks and reverts if smart pool reserve is exceeded when trying to borrow assets from the protocol.
  function checkSmartPoolReserveExceeded() internal view {
    if (smartPoolFixedBorrows + smartPoolFlexibleBorrows > smartPoolAssets.mulWadDown(1e18 - smartPoolReserveFactor))
      revert SmartPoolReserveExceeded();
  }

  /*//////////////////////////////////////////////////////////////
                    FLEXIBLE BORROW/REPAY LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @notice Borrows a certain amount from the smart pool.
  /// @param assets amount to be sent to receiver and repaid by borrower.
  /// @param receiver address that will receive the borrowed assets.
  /// @param borrower address that will repay the borrowed assets.
  function borrow(
    uint256 assets,
    address receiver,
    address borrower
  ) external nonReentrant returns (uint256 shares) {
    if (msg.sender != borrower) {
      uint256 allowed = allowance[borrower][msg.sender]; // saves gas for limited approvals.

      if (allowed != type(uint256).max) allowance[borrower][msg.sender] = allowed - previewWithdraw(assets);
    }

    updateSmartPoolFlexibleBorrows();

    shares = previewBorrow(assets);

    smartPoolFlexibleBorrows += assets;
    // we check if the underlying liquidity that the user wants to withdraw is borrowed
    if (smartPoolAssets < smartPoolFixedBorrows + smartPoolFlexibleBorrows) revert InsufficientProtocolLiquidity();

    totalFlexibleBorrowsShares += shares;
    flexibleBorrowPositions[borrower] += shares;
    checkSmartPoolReserveExceeded();

    auditor.validateBorrow(this, borrower);
    emit Borrow(msg.sender, receiver, borrower, assets, shares);
    asset.safeTransfer(receiver, assets);
  }

  /// @notice Repays a certain amount to the smart pool.
  /// @param borrowShares amount to be repaid by sender and subtracted from the borrower's debt.
  /// @param borrower address of the account that has the debt.
  function repay(uint256 borrowShares, address borrower) external nonReentrant returns (uint256 assets) {
    assets = noTransferRepay(borrowShares, borrower);
    asset.safeTransferFrom(msg.sender, address(this), assets);
  }

  function noTransferRepay(uint256 borrowShares, address borrower) internal returns (uint256 assets) {
    updateSmartPoolFlexibleBorrows();
    uint256 userBorrowShares = flexibleBorrowPositions[borrower];
    borrowShares = Math.min(borrowShares, userBorrowShares);
    assets = previewRepay(borrowShares);

    smartPoolFlexibleBorrows -= assets;
    flexibleBorrowPositions[borrower] = userBorrowShares - borrowShares;
    totalFlexibleBorrowsShares -= borrowShares;

    emit Repay(msg.sender, borrower, assets, borrowShares);
  }

  function previewBorrow(uint256 assets) public view virtual returns (uint256) {
    uint256 supply = totalFlexibleBorrowsShares; // Saves an extra SLOAD if totalFlexibleBorrowsShares is non-zero.

    return supply == 0 ? assets : assets.mulDivUp(supply, floatingBorrowAssets());
  }

  function previewRepay(uint256 shares) public view returns (uint256) {
    uint256 supply = totalFlexibleBorrowsShares; // Saves an extra SLOAD if totalFlexibleBorrowsShares is non-zero.

    return supply == 0 ? shares : shares.mulDivUp(floatingBorrowAssets(), supply);
  }

  function maxRepay(address borrower) public view returns (uint256) {
    return previewRepay(flexibleBorrowPositions[borrower]);
  }

  function floatingBorrowAssets() public view returns (uint256) {
    uint256 memTotalBorrowAssets = smartPoolFlexibleBorrows;
    uint256 spCurrentUtilization = memTotalBorrowAssets.divWadDown(
      smartPoolAssets.divWadUp(interestRateModel.flexibleFullUtilization())
    );
    uint256 newDebt = memTotalBorrowAssets.mulWadDown(
      interestRateModel.getFlexibleBorrowRate(spPreviousUtilization, spCurrentUtilization).mulDivDown(
        block.timestamp - lastUpdatedSmartPoolRate,
        365 days
      )
    );
    return memTotalBorrowAssets + newDebt;
  }

  /// @notice Updates the smart pool flexible borrows' variables.
  function updateSmartPoolFlexibleBorrows() internal {
    uint256 spCurrentUtilization = smartPoolAssets > 0
      ? smartPoolFlexibleBorrows.divWadDown(smartPoolAssets.divWadUp(interestRateModel.flexibleFullUtilization()))
      : 0;
    uint256 newDebt = smartPoolFlexibleBorrows.mulWadDown(
      interestRateModel.getFlexibleBorrowRate(spPreviousUtilization, spCurrentUtilization).mulDivDown(
        block.timestamp - lastUpdatedSmartPoolRate,
        365 days
      )
    );

    smartPoolFlexibleBorrows += newDebt;
    smartPoolAssets += chargeTreasuryFee(newDebt);
    spPreviousUtilization = spCurrentUtilization;
    lastUpdatedSmartPoolRate = block.timestamp;

    emit MarketUpdated(
      block.timestamp,
      totalSupply,
      smartPoolAssets,
      smartPoolEarningsAccumulator,
      type(uint256).max,
      0
    );
  }

  function spreadBadDebt(uint256 badDebt) internal {
    uint256 memEarningsAccumulator = smartPoolEarningsAccumulator;
    uint256 fromAccumulator = Math.min(memEarningsAccumulator, badDebt);
    smartPoolEarningsAccumulator = memEarningsAccumulator - fromAccumulator;
    if (fromAccumulator < badDebt) smartPoolAssets -= badDebt - fromAccumulator;
  }

  /// @notice Charges treasury fee to certain amount of earnings.
  /// @dev Mints amount of eTokens on behalf of the treasury address.
  /// @param earnings amount of earnings.
  /// @return earnings minus the fees charged by the treasury.
  function chargeTreasuryFee(uint256 earnings) internal returns (uint256) {
    uint256 memTreasuryFee = treasuryFee;
    if (memTreasuryFee == 0 || earnings == 0) return earnings;

    uint256 assets = earnings.mulWadDown(memTreasuryFee);
    _mint(treasury, previewDeposit(assets));
    smartPoolAssets += assets;
    return earnings - assets;
  }

  /// @notice Collects all earnings that are charged to borrowers that make use of fixed pool
  /// deposits' assets.
  /// @dev Mints amount of eTokens on behalf of the treasury address.
  /// @param earnings amount of earnings.
  function collectFreeLunch(uint256 earnings) internal {
    if (earnings == 0) return;

    if (treasuryFee > 0) {
      _mint(treasury, previewDeposit(earnings));
      smartPoolAssets += earnings;
    } else {
      smartPoolEarningsAccumulator += earnings;
    }
  }
}

error AlreadyInitialized();
error NotFixedLender();
error SelfLiquidation();
error SmartPoolReserveExceeded();
error TooMuchSlippage();
error ZeroWithdraw();
error ZeroRepay();
