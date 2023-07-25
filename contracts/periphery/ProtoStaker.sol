// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { WETH, ERC20 } from "solmate/src/tokens/WETH.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { RewardsController, ClaimPermit } from "./../RewardsController.sol";
import { EXA } from "./EXA.sol";

contract ProtoStaker is Initializable {
  using SafeERC20Upgradeable for EXA;
  using SafeTransferLib for address payable;
  using SafeTransferLib for ERC20;
  using SafeTransferLib for WETH;

  /// @notice The EXA asset.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  EXA public immutable exa;
  /// @notice The WETH asset.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  WETH public immutable weth;
  /// @notice The liquidity pool.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPool public immutable pool;
  /// @notice The gauge used to stake the liquidity pool tokens.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IGauge public immutable gauge;
  /// @notice The rewards controller.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  RewardsController public immutable rewardsController;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(EXA exa_, WETH weth_, IPool pool_, IGauge gauge_, RewardsController rewardsController_) {
    exa = exa_;
    weth = weth_;
    pool = pool_;
    gauge = gauge_;
    rewardsController = rewardsController_;

    _disableInitializers();
  }

  function initialize() external initializer {
    ERC20(address(pool)).safeApprove(address(gauge), type(uint256).max);
  }

  function stakeBalance(Permit calldata permit) external payable {
    exa.safePermit(permit.account, address(this), permit.amount, permit.deadline, permit.v, permit.r, permit.s);
    exa.safeTransferFrom(permit.account, address(pool), permit.amount);
    stake(permit.amount, permit.account);
  }

  function stakeRewards(ClaimPermit calldata permit) external payable {
    assert(permit.assets.length == 1 && address(permit.assets[0]) == address(exa));
    (, uint256[] memory claimedAmounts) = rewardsController.claim(rewardsController.allMarketsOperations(), permit);
    exa.safeTransfer(address(pool), claimedAmounts[0]);
    stake(claimedAmounts[0], payable(permit.owner));
  }

  function stake(uint256 amountEXA, address payable account) internal {
    uint256 amountETH = previewETH(amountEXA);
    if (msg.value < amountETH) {
      account.safeTransferETH(msg.value);
      pool.skim(account);
      return;
    }

    weth.deposit{ value: amountETH }();
    weth.safeTransfer(address(pool), amountETH);
    gauge.deposit(pool.mint(address(this)), account);
    account.safeTransferETH(msg.value - amountETH);
  }

  function previewETH(uint256 amountEXA) public view returns (uint256) {
    (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
    return address(exa) < address(weth) ? (amountEXA * reserve1) / reserve0 : (amountEXA * reserve0) / reserve1;
  }
}

interface IPool {
  function skim(address to) external;

  function mint(address to) external returns (uint256 liquidity);

  function balanceOf(address account) external view returns (uint256);

  function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
}

interface IGauge {
  function deposit(uint256 amount, address recipient) external;

  function balanceOf(address account) external view returns (uint256);
}

struct Permit {
  address payable account;
  uint256 amount;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}
