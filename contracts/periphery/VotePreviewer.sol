// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

/// @title Vote Previewer
/// @notice Contract to be consumed by voting strategies.
contract VotePreviewer {
  using FixedPointMathLib for uint256;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  address public immutable exa;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPool public immutable pool;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IERC20 public immutable gauge;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IExtraLending public immutable extraLending;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  uint256 public immutable extraReserveId;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(address exa_, IPool pool_, IERC20 gauge_, IExtraLending extraLending_, uint256 extraReserveId_) {
    exa = exa_;
    pool = pool_;
    gauge = gauge_;
    extraLending = extraLending_;
    extraReserveId = extraReserveId_;
  }

  function externalVotes(address account) external view returns (uint256 votes) {
    uint256 liquidity = pool.balanceOf(account) + gauge.balanceOf(account);
    votes += liquidity.mulDivDown(exa == pool.token0() ? pool.reserve0() : pool.reserve1(), pool.totalSupply());

    uint256[] memory reserveIds = new uint256[](1);
    reserveIds[0] = extraReserveId;
    IExtraLending.PositionStatus[] memory e = extraLending.getPositionStatus(reserveIds, account);
    votes += extraLending.exchangeRateOfReserve(extraReserveId).mulWadDown(e[0].eTokenStaked + e[0].eTokenUnStaked);
  }
}

interface IPool is IERC20 {
  function token0() external view returns (address);

  function reserve0() external view returns (uint256);

  function reserve1() external view returns (uint256);
}

interface IExtraLending {
  struct PositionStatus {
    uint256 reserveId;
    address user;
    uint256 eTokenStaked;
    uint256 eTokenUnStaked;
    uint256 liquidity;
  }

  function getPositionStatus(
    uint256[] memory reserveIds,
    address account
  ) external view returns (PositionStatus[] memory);

  function exchangeRateOfReserve(uint256 reserveId) external view returns (uint256);
}
