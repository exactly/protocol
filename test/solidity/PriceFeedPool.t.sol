// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { PriceFeedPool, IPriceFeed, IPool, ERC20 } from "../../contracts/PriceFeedPool.sol";
import { MockPriceFeed } from "../../contracts/mocks/MockPriceFeed.sol";

contract PriceFeedPoolTest is Test {
  using FixedPointMathLib for uint256;

  PriceFeedPool internal priceFeedPool;
  MockPriceFeed internal ethPriceFeed;
  MockPool internal mockPool;

  function setUp() external {
    mockPool = new MockPool(new MockERC20("WETH", "WETH", 18), new MockERC20("EXA", "EXA", 18), 100e18, 500e18);
    ethPriceFeed = new MockPriceFeed(18, 2_000e18);
    priceFeedPool = new PriceFeedPool(mockPool, ethPriceFeed, true);
  }

  function testPriceFeedPoolReturningPrice() external {
    (uint256 reserve0, uint256 reserve1, ) = mockPool.getReserves();
    uint256 usdPrice = uint256(ethPriceFeed.latestAnswer()).mulDivDown(reserve0, reserve1);
    assertEq(usdPrice, 400e18);
    assertEq(uint256(priceFeedPool.latestAnswer()), usdPrice);
  }

  function testPriceFeedPoolWithDifferentDecimals() external {
    priceFeedPool = new PriceFeedPool(
      new MockPool(new MockERC20("WETH", "WETH", 18), new MockERC20("EXA", "EXA", 8), 100e18, 500e8),
      ethPriceFeed,
      true
    );
    uint256 usdPrice = (((100e18 * 1e8) / 500e8) * 2_000e18) / 1e18;
    assertEq(usdPrice, 400e18);
    assertEq(uint256(priceFeedPool.latestAnswer()), usdPrice);
  }

  function testPriceFeedPoolReturningPriceWithToken0False() external {
    mockPool = new MockPool(new MockERC20("EXA", "EXA", 18), new MockERC20("WETH", "WETH", 18), 500e18, 100e18);
    priceFeedPool = new PriceFeedPool(IPool(address(mockPool)), IPriceFeed(address(ethPriceFeed)), false);
    (uint256 reserve0, uint256 reserve1, ) = mockPool.getReserves();
    uint256 usdPrice = uint256(ethPriceFeed.latestAnswer()).mulDivDown(reserve1, reserve0);
    assertEq(usdPrice, 400e18);
    assertEq(uint256(priceFeedPool.latestAnswer()), usdPrice);
  }

  function testPriceFeedPoolWithDifferentDecimalsWithToken0False() external {
    mockPool = new MockPool(new MockERC20("EXA", "EXA", 8), new MockERC20("WETH", "WETH", 18), 500e8, 100e18);
    priceFeedPool = new PriceFeedPool(IPool(address(mockPool)), IPriceFeed(address(ethPriceFeed)), false);
    uint256 usdPrice = (((100e18 * 1e8) / 500e8) * 2_000e18) / 1e18;
    assertEq(usdPrice, 400e18);
    assertEq(uint256(priceFeedPool.latestAnswer()), usdPrice);
  }

  function testPriceFeedPoolWithAllDifferentDecimals() external {
    priceFeedPool = new PriceFeedPool(
      IPool(address(new MockPool(new MockERC20("WETH", "WETH", 8), new MockERC20("EXA", "EXA", 10), 100e8, 500e10))),
      IPriceFeed(address(ethPriceFeed)),
      true
    );
    uint256 usdPrice = (((100e8 * 1e10) / 500e10) * 2_000e18) / 1e8;
    assertEq(usdPrice, 400e18);
    assertEq(uint256(priceFeedPool.latestAnswer()), usdPrice);
  }

  function testPriceFeedPoolWithAllDifferentDecimalsWithToken0False() external {
    mockPool = new MockPool(new MockERC20("EXA", "EXA", 8), new MockERC20("WETH", "WETH", 10), 500e8, 100e10);
    priceFeedPool = new PriceFeedPool(IPool(address(mockPool)), IPriceFeed(address(ethPriceFeed)), false);
    uint256 usdPrice = (((100e10 * 1e8) / 500e8) * 2_000e18) / 1e10;
    assertEq(usdPrice, 400e18);
    assertEq(uint256(priceFeedPool.latestAnswer()), usdPrice);
  }
}

contract MockPool is IPool {
  ERC20 public token0;
  ERC20 public token1;
  uint256 public reserve0;
  uint256 public reserve1;

  constructor(ERC20 token0_, ERC20 token1_, uint256 reserve0_, uint256 reserve1_) {
    token0 = token0_;
    token1 = token1_;
    reserve0 = reserve0_;
    reserve1 = reserve1_;
  }

  function getReserves() external view returns (uint256, uint256, uint256) {
    return (reserve0, reserve1, 0);
  }
}
