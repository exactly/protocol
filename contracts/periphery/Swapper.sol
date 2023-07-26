// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { WETH, ERC20 } from "solmate/src/tokens/WETH.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";

contract Swapper {
  using SafeTransferLib for address payable;
  using SafeTransferLib for WETH;

  /// @notice The EXA asset.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ERC20 public immutable exa;
  /// @notice The WETH asset.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  WETH public immutable weth;
  /// @notice The liquidity pool.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPool public immutable pool;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(ERC20 exa_, WETH weth_, IPool pool_) {
    exa = exa_;
    weth = weth_;
    pool = pool_;
  }

  /// @notice Swaps `msg.value` ETH for EXA and sends it to `account`.
  /// @param account The account to send the EXA to.
  /// @param minEXA The minimum amount of EXA to receive.
  /// @param keepETH The amount of ETH to send to `account` (ex: for gas).
  function swap(address payable account, uint256 minEXA, uint256 keepETH) external payable {
    if (keepETH > msg.value) return account.safeTransferETH(msg.value);

    uint256 inETH = msg.value - keepETH;
    uint256 outEXA = pool.getAmountOut(inETH, weth);
    if (outEXA < minEXA) return account.safeTransferETH(msg.value);

    weth.deposit{ value: inETH }();
    weth.safeTransfer(address(pool), inETH);

    (uint256 amount0Out, uint256 amount1Out) = address(exa) < address(weth)
      ? (outEXA, uint256(0))
      : (uint256(0), outEXA);
    try pool.swap(amount0Out, amount1Out, account, "") {
      account.safeTransferETH(keepETH);
    } catch {
      account.safeTransferETH(msg.value);
    }
  }
}

interface IPool {
  function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

  function getAmountOut(uint256 amountIn, WETH tokenIn) external view returns (uint256);
}
