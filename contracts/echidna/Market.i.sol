// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.16;

import { Auditor, ERC20, FixedLib, InterestRateModel, Market, Math } from "../../contracts/Market.sol";

contract MarketInvariants {
  Auditor internal immutable auditor = Auditor(0x0B1ba0af832d7C05fD64161E0Db78E85978E8082);
  Market internal immutable marketDAI = Market(0xcFC18CEc799fBD1793B5C43E773C98D4d61Cc2dB);
  ERC20 internal immutable dai = Market(0x34D402F14D58E001D8EfBe6585051BF9706AA064);

  function invariantDeposit() external returns (bool) {
    uint256 balance = dai.balanceOf(address(marketDAI));
    return marketDAI.deposit(balance, msg.sender) > 0;
  }

  // function invariantAccountLiquidity() external view returns (bool) {
  //   (uint256 collateral, uint256 debt) = auditor.accountLiquidity(msg.sender, Market(address(0)), 0);
  //   return collateral >= debt;
  // }

  // function invariantFloatingBackupBorrowed() external view returns (bool) {
  //   uint256 floatingBackupBorrowed = 0;
  //   uint256 maxFuturePools = market.maxFuturePools();
  //   uint256 maxMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL)
  //     + maxFuturePools * FixedLib.INTERVAL;

  //   for (uint256 maturity = FixedLib.INTERVAL; maturity <= maxMaturity; maturity += FixedLib.INTERVAL) {
  //     (uint256 borrowed, uint256 supplied, , ) = market.fixedPools(maturity);
  //     floatingBackupBorrowed += borrowed - Math.min(borrowed, supplied);
  //   }

  //   return floatingBackupBorrowed == market.floatingBackupBorrowed();
  // }
}
