// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { IPriceFeed } from "./utils/IPriceFeed.sol";

contract PriceFeedPool is IPriceFeed {
  using FixedPointMathLib for uint256;

  /// @notice Base price feed where the price is fetched from.
  IPriceFeed public immutable basePriceFeed;
  /// @notice Base unit of pool's token0.
  uint256 public immutable baseUnit0;
  /// @notice Base unit of pool's token1.
  uint256 public immutable baseUnit1;
  /// @notice Number of decimals that the answer of this price feed has.
  uint8 public immutable decimals;
  /// @notice Whether the pool's token1 is the base price feed's asset.
  bool public immutable token1Based;
  /// @notice Pool where the exchange rate is fetched from.
  IPool public immutable pool;

  constructor(IPool pool_, IPriceFeed basePriceFeed_, bool token1Based_) {
    pool = pool_;
    token1Based = token1Based_;
    basePriceFeed = basePriceFeed_;
    decimals = basePriceFeed_.decimals();
    baseUnit0 = 10 ** pool_.token0().decimals();
    baseUnit1 = 10 ** pool_.token1().decimals();
  }

  /// @notice Returns the price feed's latest value considering the pool's reserves (exchange rate).
  /// @dev Value should only be used for display purposes since pool reserves can be easily manipulated.
  function latestAnswer() external view returns (int256) {
    int256 mainPrice = basePriceFeed.latestAnswer();
    (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
    return
      int256(
        token1Based
          ? uint256(mainPrice).mulDivDown((reserve1 * baseUnit0) / reserve0, baseUnit1)
          : uint256(mainPrice).mulDivDown((reserve0 * baseUnit1) / reserve1, baseUnit0)
      );
  }
}

interface IPool {
  function token0() external view returns (ERC20);

  function token1() external view returns (ERC20);

  function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
}
