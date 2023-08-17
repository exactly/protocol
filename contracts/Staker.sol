// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { WETH, ERC20, SafeTransferLib } from "solmate/src/tokens/WETH.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { IERC6372Upgradeable } from "@openzeppelin/contracts-upgradeable/interfaces/IERC6372Upgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import {
  ERC20Upgradeable,
  ERC20PermitUpgradeable,
  IERC20Upgradeable as IERC20,
  IERC20PermitUpgradeable as IERC20Permit
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { RewardsController, Auditor, Market, ClaimPermit } from "./RewardsController.sol";

contract Staker is ERC4626Upgradeable, ERC20PermitUpgradeable, IERC6372Upgradeable {
  using SafeERC20Upgradeable for IERC20Permit;
  using FixedPointMathLib for uint256;
  using SafeTransferLib for address payable;
  using SafeTransferLib for ERC20;
  using SafeTransferLib for WETH;

  /// @notice The EXA asset.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ERC20 public immutable exa;
  /// @notice The WETH asset.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  WETH public immutable weth;
  /// @notice The VELO asset.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ERC20 public immutable velo;
  /// @notice The liquidity pool.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IGauge public immutable gauge;
  /// @notice Velodrome's voter.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IVoter public immutable voter;
  /// @notice Velodrome's fees.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IReward public immutable fees;
  /// @notice Velodrome's bribes.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IReward public immutable bribes;
  /// @notice Velodrome's minter.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IMinter public immutable minter;
  /// @notice exactly's auditor.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;
  /// @notice The factory where the fee will be fetched from.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPoolFactory public immutable factory;
  /// @notice Velodrome's voting escrow.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IVotingEscrow public immutable votingEscrow;
  /// @notice The rewards controller.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  RewardsController public immutable rewardsController;
  /// @notice Velodrome's rebase distributor.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IRewardsDistributor public immutable distributor;

  uint256 public lockId;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    ERC20 exa_,
    WETH weth_,
    IVoter voter_,
    Auditor auditor_,
    IPoolFactory factory_,
    IVotingEscrow votingEscrow_,
    RewardsController rewardsController_
  ) {
    exa = exa_;
    weth = weth_;
    voter = voter_;
    auditor = auditor_;
    factory = factory_;
    votingEscrow = votingEscrow_;
    rewardsController = rewardsController_;
    velo = votingEscrow_.token();
    gauge = voter_.gauges(factory_.getPool(exa_, weth_, false));
    fees = gauge.feesVotingReward();
    bribes = voter.gaugeToBribe(gauge);
    minter = voter.minter();
    distributor = minter.rewardsDistributor();

    _disableInitializers();
  }

  function initialize() external initializer {
    __ERC20_init("exactly staker", "stEXA");
    __ERC4626_init(factory.getPool(exa, weth, false));
    __ERC20Permit_init("exactly staker");

    ERC20 pool = ERC20(asset());
    pool.safeApprove(address(this), type(uint256).max);
    pool.safeApprove(address(gauge), type(uint256).max);
    velo.safeApprove(address(votingEscrow), type(uint256).max);
  }

  function stake(address payable account, uint256 inEXA, uint256 minEXA, uint256 keepETH) internal {
    if (keepETH >= msg.value) return returnAssets(account, inEXA);

    uint256 inETH = msg.value - keepETH;
    if (inETH < previewETH(inEXA)) return returnAssets(account, inEXA);

    weth.deposit{ value: inETH }();
    uint256 liquidity = swapAndDeposit(inEXA, inETH, minEXA);
    if (liquidity == 0) {
      weth.withdraw(inETH);
      return returnAssets(account, inEXA);
    }
    this.deposit(liquidity, account);

    if (keepETH != 0) account.safeTransferETH(keepETH);
  }

  function unstake(address account, uint256 percentage) external {
    assert(percentage != 0);

    IPool pool = IPool(asset());
    redeem(balanceOf(account).mulWadDown(percentage), address(pool), account);
    (uint256 amount0, uint256 amount1) = pool.burn(this);

    (uint256 amountEXA, uint256 amountETH) = address(exa) < address(weth) ? (amount0, amount1) : (amount1, amount0);
    exa.safeTransfer(msg.sender, amountEXA);
    weth.withdraw(amountETH);
    payable(msg.sender).safeTransferETH(amountETH);
  }

  function harvest() public {
    if (gauge.earned(this) != 0) gauge.getReward(this);

    uint256 id = lockId;
    if (id != 0) {
      {
        uint256 period = minter.activePeriod();
        if (distributor.timeCursorOf(id) != period && period >= block.timestamp - (block.timestamp % 1 weeks)) {
          distributor.claim(id);
        }
      }

      ERC20[] memory assets = new ERC20[](2);
      assets[0] = exa;
      assets[1] = weth;
      fees.getReward(id, assets);

      {
        uint256 count = 0;
        ERC20[] memory a = new ERC20[](bribes.rewardsListLength());
        for (uint256 i = 0; i < a.length; ++i) {
          ERC20 reward = bribes.rewards(i);
          if (bribes.earned(reward, id) != 0) a[count++] = reward;
        }
        assets = new ERC20[](count);
        for (uint256 i = 0; i < assets.length; ++i) assets[i] = a[i];
      }
      if (assets.length != 0) {
        bribes.getReward(id, assets);
        for (uint256 i = 0; i < assets.length; ++i) handleReward(assets[i]);
      }
    }

    Market[] memory markets = auditor.allMarkets();
    for (uint256 i = 0; i < markets.length; ++i) {
      address treasury = markets[i].treasury();
      if (treasury == address(0)) continue;
      uint256 allowed = markets[i].allowance(treasury, address(this));
      if (allowed == 0) continue;
      uint256 shares = markets[i].balanceOf(treasury);
      if (shares == 0) continue;
      markets[i].redeem(allowed < shares ? allowed : shares, address(this), treasury);
      handleReward(markets[i].asset());
    }

    uint256 balanceVELO = velo.balanceOf(address(this));
    if (
      balanceVELO != 0 &&
      block.timestamp > block.timestamp - (block.timestamp % 1 weeks) + 1 hours &&
      block.timestamp <= block.timestamp - (block.timestamp % 1 weeks) + 1 weeks - 1 hours
    ) {
      if (id == 0) {
        IPool[] memory pools = new IPool[](1);
        uint256[] memory weights = new uint256[](1);
        pools[0] = IPool(asset());
        weights[0] = 100e18;
        id = votingEscrow.createLock(balanceVELO, 4 * 365 days);
        lockId = id;
        votingEscrow.lockPermanent(id);
        voter.vote(id, pools, weights);
      } else {
        votingEscrow.increaseAmount(id, balanceVELO);
        voter.poke(id);
      }
    }

    uint256 balanceWETH = weth.balanceOf(address(this));
    if (balanceWETH != 0) gauge.deposit(swapAndDeposit(exa.balanceOf(address(this)), balanceWETH, 0));
  }

  function handleReward(ERC20 assetIn) internal {
    if (assetIn == exa && assetIn == weth && assetIn == velo) return;

    IPool pool = factory.getPool(assetIn, weth, false);
    if (address(pool) == address(0)) return;

    uint256 amountIn = assetIn.balanceOf(address(this));
    uint256 outWETH = pool.getAmountOut(amountIn, assetIn);
    assetIn.safeTransfer(address(pool), amountIn);
    (uint256 out0, uint256 out1) = address(assetIn) < address(weth) ? (uint256(0), outWETH) : (outWETH, uint256(0));
    pool.swap(out0, out1, this, "");
  }

  /// @dev spares extra EXA, inEXA = min(inEXA, maxEXA)
  function swapAndDeposit(uint256 inEXA, uint256 inWETH, uint256 minEXA) internal returns (uint256 liquidity) {
    IPool pool = IPool(asset());

    uint256 reserveEXA;
    uint256 reserveWETH;
    {
      (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
      (reserveEXA, reserveWETH) = address(exa) < address(weth) ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    {
      uint256 maxEXA = inWETH.mulDivDown(reserveEXA, reserveWETH);
      if (inEXA < maxEXA) {
        uint256 fee = factory.getFee(pool, false);
        uint256 extraWETH = inWETH - inEXA.mulDivDown(reserveWETH, reserveEXA);
        uint256 swapWETH = (extraWETH / 2).mulDivDown(1e4 - fee, 1e4);
        uint256 outEXA = swapWETH.mulDivDown(reserveEXA, swapWETH + reserveWETH).mulDivDown(1e4 - fee, 1e4);
        if (outEXA + inEXA < minEXA) return 0;

        (uint256 out0, uint256 out1) = address(exa) < address(weth) ? (outEXA, uint256(0)) : (uint256(0), outEXA);
        weth.safeTransfer(address(pool), swapWETH);
        pool.swap(out0, out1, this, "");
        inWETH -= swapWETH;
        inEXA += outEXA;
      } else inEXA = maxEXA;
    }

    exa.safeTransfer(address(pool), inEXA);
    weth.safeTransfer(address(pool), inWETH);
    return pool.mint(this);
  }

  function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
    super._deposit(caller, receiver, assets, shares);
    gauge.deposit(assets);
    harvest();
  }

  function _withdraw(
    address caller,
    address receiver,
    address owner,
    uint256 assets,
    uint256 shares
  ) internal override {
    if (assets > 0) gauge.withdraw(assets);
    super._withdraw(caller, receiver, owner, assets, shares);
    harvest();
  }

  function totalAssets() public view override returns (uint256) {
    return gauge.balanceOf(address(this));
  }

  function returnAssets(address payable account, uint256 amountEXA) internal {
    account.safeTransferETH(msg.value);
    exa.safeTransfer(account, amountEXA);
  }

  function stakeETH(address payable account, uint256 minEXA, uint256 keepETH) external payable {
    stake(account, 0, minEXA, keepETH);
  }

  function stakeBalance(address payable account, uint256 inEXA, uint256 minEXA, uint256 keepETH) public payable {
    exa.safeTransferFrom(account, address(this), inEXA);
    stake(account, inEXA, minEXA, keepETH);
  }

  function stakeBalance(Permit calldata p, uint256 minEXA, uint256 keepETH) external payable {
    IERC20Permit(address(exa)).safePermit(p.owner, address(this), p.value, p.deadline, p.v, p.r, p.s);
    stakeBalance(p.owner, p.value, minEXA, keepETH);
  }

  function stakeRewards(ClaimPermit calldata p, uint256 minEXA, uint256 keepETH) external payable {
    if (p.assets.length != 1 || address(p.assets[0]) != address(exa)) {
      return payable(p.owner).safeTransferETH(msg.value);
    }
    (, uint256[] memory claimedAmounts) = rewardsController.claim(rewardsController.allMarketsOperations(), p);
    if (claimedAmounts[0] == 0) return payable(p.owner).safeTransferETH(msg.value);
    stake(payable(p.owner), claimedAmounts[0], minEXA, keepETH);
  }


  function previewETH(uint256 amountEXA) public view returns (uint256) {
    (uint256 reserve0, uint256 reserve1, ) = IPool(asset()).getReserves();
    return
      address(exa) < address(weth)
        ? amountEXA.mulDivDown(reserve1, reserve0)
        : amountEXA.mulDivDown(reserve0, reserve1);
  }

  function decimals() public view override(ERC4626Upgradeable, ERC20Upgradeable) returns (uint8) {
    return ERC4626Upgradeable.decimals();
  }

  function clock() public view override returns (uint48) {
    return uint48(block.timestamp);
  }

  // solhint-disable-next-line func-name-mixedcase
  function CLOCK_MODE() public pure override returns (string memory) {
    return "mode=timestamp";
  }

  // solhint-disable-next-line no-empty-blocks
  receive() external payable {}
}

struct Permit {
  address payable owner;
  uint256 value;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}

interface IPool is IERC20, IERC20Permit {
  function mint(Staker to) external returns (uint256 liquidity);

  function burn(Staker to) external returns (uint256 amount0, uint256 amount1);

  function swap(uint256 amount0Out, uint256 amount1Out, Staker to, bytes calldata data) external;

  function poolFees() external view returns (address);

  function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);

  function getAmountOut(uint256 amountIn, ERC20 tokenIn) external view returns (uint256);
}

interface IGauge is IERC20, IERC20Permit {
  function earned(Staker account) external view returns (uint256);

  function deposit(uint256 amount) external;

  function withdraw(uint256 amount) external;

  function getReward(Staker account) external;

  function feesVotingReward() external view returns (IReward);
}

interface IVoter {
  function minter() external view returns (IMinter);

  function gauges(IPool pool) external view returns (IGauge);

  function poke(uint256 tokenId) external;

  function vote(uint256 tokenId, IPool[] calldata poolVote, uint256[] calldata weights) external;

  function weights(IPool pool) external view returns (uint256);

  function distribute(IGauge[] memory gauges) external;

  function usedWeights(uint256 tokenId) external view returns (uint256);

  function gaugeToBribe(IGauge gauge) external view returns (IReward);
}

interface IVotingEscrow {
  function token() external view returns (ERC20);

  function locked(uint256 tokenId) external view returns (LockedBalance memory);

  function createLock(uint256 value, uint256 lockDuration) external returns (uint256);

  function lockPermanent(uint256 tokenId) external;

  function increaseAmount(uint256 tokenId, uint256 value) external;
}

interface IPoolFactory {
  function getFee(IPool pool, bool stable) external view returns (uint256);

  function getPool(ERC20 tokenA, ERC20 tokenB, bool stable) external view returns (IPool);
}

interface IReward {
  function earned(ERC20 token, uint256 tokenId) external view returns (uint256);

  function rewards(uint256 index) external view returns (ERC20);

  function getReward(uint256 tokenId, ERC20[] memory tokens) external;

  function rewardsListLength() external view returns (uint256);

  function notifyRewardAmount(ERC20 token, uint256 amount) external;

  function tokenRewardsPerEpoch(ERC20 token, uint256 epochStart) external view returns (uint256);
}

interface IMinter {
  function activePeriod() external returns (uint256);

  function rewardsDistributor() external view returns (IRewardsDistributor);
}

interface IRewardsDistributor {
  function claim(uint256 tokenId) external returns (uint256);

  function claimable(uint256 tokenId) external view returns (uint256);

  function timeCursorOf(uint256 tokenId) external view returns (uint256);
}

struct LockedBalance {
  int128 amount;
  uint256 end;
  bool isPermanent;
}
