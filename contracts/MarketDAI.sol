// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC4626, ERC20, SafeTransferLib } from "solmate/src/mixins/ERC4626.sol";
import { Market, Auditor, InterestRateModel, FixedLib } from "./Market.sol";

contract MarketDAI is Market {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;

  DAIPot public daiPot;
  DAIJoin public daiJoin;
  uint256 public lastChi;

  constructor(ERC20 dai, Auditor auditor_) Market(dai, auditor_) {} // solhint-disable-line no-empty-blocks

  function dsrConfig(DAIPot daiPot_, DAIJoin daiJoin_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (
      (address(daiPot_) == address(0) && address(daiJoin_) != address(0)) ||
      (address(daiPot_) != address(0) && address(daiJoin_) == address(0))
    ) revert InvalidDSR();

    DAIPot prevPot = daiPot;
    DAIJoin prevJoin = daiJoin;

    daiPot = daiPot_;
    daiJoin = daiJoin_;

    if (address(daiPot_) != address(0)) {
      asset.safeApprove(address(daiJoin_), type(uint256).max);
      DAIVat vat = daiPot_.vat();
      vat.hope(address(daiPot_));
      vat.hope(address(daiJoin_));

      uint256 balance = asset.balanceOf(address(this));
      if (balance != 0) dsrDeposit(balance);
    } else {
      uint256 shares = prevPot.pie(address(this));
      prevPot.exit(shares);
      prevJoin.exit(
        address(this),
        shares.mulDivDown(block.timestamp > prevPot.rho() ? prevPot.drip() : prevPot.chi(), 1e27)
      );

      asset.safeApprove(address(prevJoin), 0);
      DAIVat vat = prevPot.vat();
      vat.nope(address(prevPot));
      vat.nope(address(prevJoin));
    }
  }

  function dsrDeposit(uint256 amount) internal {
    DAIPot memPot = daiPot;
    if (address(memPot) == address(0)) return;

    uint256 chi = block.timestamp > memPot.rho() ? memPot.drip() : memPot.chi();
    floatingAssets += memPot.pie(address(this)).mulDivDown(chi - lastChi, 1e27);

    daiJoin.join(address(this), amount);
    memPot.join(amount.mulDivDown(1e27, chi));

    lastChi = chi;
  }

  function dsrWithdraw(uint256 amount) internal {
    DAIPot memPot = daiPot;
    if (address(memPot) == address(0)) return;

    uint256 chi = block.timestamp > memPot.rho() ? memPot.drip() : memPot.chi();
    floatingAssets += memPot.pie(address(this)).mulDivDown(chi - lastChi, 1e27);

    memPot.exit(amount.mulDivUp(1e27, chi));
    daiJoin.exit(address(this), amount);

    lastChi = chi;
  }

  function totalAssets() public view virtual override returns (uint256 assets) {
    assets = super.totalAssets();
    DAIPot memPot = daiPot;
    if (address(memPot) != address(0)) {
      assets += memPot.pie(address(this)).mulDivDown(
        memPot.dsr().rpow(block.timestamp - memPot.rho(), 1e27).mulDivDown(memPot.chi(), 1e27) - lastChi,
        1e27
      );
    }
  }

  function transferAssetOut(address to, uint256 amount) internal override {
    dsrWithdraw(amount);
    asset.safeTransfer(to, amount);
  }

  function transferAssetIn(address from, uint256 amount) internal override {
    asset.safeTransferFrom(from, address(this), amount);
    dsrDeposit(amount);
  }

  function afterDeposit(uint256 assets, uint256 shares) internal override {
    dsrDeposit(assets);
    super.afterDeposit(assets, shares);
  }

  function beforeWithdraw(uint256 assets, uint256 shares) internal override {
    dsrWithdraw(assets);
    super.beforeWithdraw(assets, shares);
  }
}

error InvalidDSR();

interface DAIJoin {
  function join(address account, uint256 amount) external;

  function exit(address account, uint256 amount) external;
}

interface DAIPot {
  function vat() external view returns (DAIVat);

  function dsr() external view returns (uint256);

  function rho() external view returns (uint256);

  function chi() external view returns (uint256);

  function drip() external returns (uint256);

  function pie(address account) external view returns (uint256 shares);

  function join(uint256 shares) external;

  function exit(uint256 shares) external;
}

interface DAIVat {
  function hope(address account) external;

  function nope(address account) external;
}
