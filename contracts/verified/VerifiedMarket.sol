// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { ERC20, FixedLib, Market, NotAuditor, RewardsController } from "../Market.sol";
import { NotAllowed, VerifiedAuditor } from "./VerifiedAuditor.sol";

contract VerifiedMarket is Market {
  mapping(address account => uint256 assets) public lockedAssets;

  constructor(ERC20 asset_, VerifiedAuditor auditor_) Market(asset_, auditor_) {}

  function deposit(
    uint256 assets,
    address receiver
  ) public override onlyAllowed(msg.sender) onlyAllowed(receiver) returns (uint256 shares) {
    return super.deposit(assets, receiver);
  }

  function mint(
    uint256 shares,
    address receiver
  ) public override onlyAllowed(msg.sender) onlyAllowed(receiver) returns (uint256 assets) {
    return super.mint(shares, receiver);
  }

  function depositAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired,
    address receiver
  ) public override onlyAllowed(msg.sender) onlyAllowed(receiver) returns (uint256) {
    return super.depositAtMaturity(maturity, assets, minAssetsRequired, receiver);
  }

  function lock(address account) external {
    if (msg.sender != address(auditor)) revert NotAuditor();

    uint256 shares = balanceOf[account];
    uint256 assets = convertToAssets(shares);
    beforeWithdraw(assets, shares);
    _burn(account, shares);

    // iterate over all the fixed deposits
    uint256 packedMaturities = accounts[account].fixedDeposits;
    uint256 maturity = packedMaturities & ((1 << 32) - 1);
    packedMaturities = packedMaturities >> 32;
    while (packedMaturities != 0) {
      if (packedMaturities & 1 != 0) {
        FixedLib.Position memory position = fixedDepositPositions[maturity][account];
        uint256 positionAssets = position.principal + position.fee;
        if (positionAssets != 0) {
          (uint256 assetsDiscounted, FixedLib.Pool storage pool, , ) = _prepareWithdrawAtMaturity(
            maturity,
            positionAssets,
            0,
            account
          );
          _processWithdrawAtMaturity(pool, position, maturity, positionAssets, account, assetsDiscounted);

          assets += assetsDiscounted;
        }
      }
      packedMaturities >>= 1;
      maturity += FixedLib.INTERVAL;
    }

    lockedAssets[account] += assets;

    emit Seize(msg.sender, account, assets);
    emit Locked(account, assets);
    emitMarketUpdate();
  }

  function liquidate(
    address borrower,
    uint256 maxAssets,
    Market seizeMarket
  ) public override onlyAllowed(msg.sender) returns (uint256 repaidAssets) {
    return super.liquidate(borrower, maxAssets, seizeMarket);
  }

  function refund(
    uint256 borrowShares,
    address borrower
  ) public override onlyAllowed(msg.sender) onlyAllowed(borrower) returns (uint256 assets, uint256 actualShares) {
    return super.refund(borrowShares, borrower);
  }

  function repay(
    uint256 assets,
    address borrower
  ) public override onlyAllowed(msg.sender) onlyAllowed(borrower) returns (uint256 actualRepay, uint256 borrowShares) {
    return super.repay(assets, borrower);
  }

  function repayAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 maxAssets,
    address borrower
  ) public override onlyAllowed(msg.sender) onlyAllowed(borrower) returns (uint256 actualRepayAssets) {
    return super.repayAtMaturity(maturity, assets, maxAssets, borrower);
  }

  function transfer(address to, uint256 shares) public override onlyAllowed(to) returns (bool) {
    return super.transfer(to, shares);
  }

  function transferFrom(address from, address to, uint256 shares) public override onlyAllowed(to) returns (bool) {
    return super.transferFrom(from, to, shares);
  }

  function withdrawAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 minAssetsRequired,
    address receiver,
    address owner
  ) public override onlyAllowed(owner) returns (uint256 assetsDiscounted) {
    return super.withdrawAtMaturity(maturity, positionAssets, minAssetsRequired, receiver, owner);
  }

  function _requireAllowed(address account) internal view {
    if (!VerifiedAuditor(address(auditor)).firewall().isAllowed(account)) revert NotAllowed(account);
  }

  function handleRewards(bool, address) internal override {} // solhint-disable-line no-empty-blocks

  function setRewardsController(RewardsController) public override {} // solhint-disable-line no-empty-blocks

  function rewardsController() external pure override returns (RewardsController) {
    return RewardsController(address(0));
  }

  modifier onlyAllowed(address account) {
    _requireAllowed(account);
    _;
  }
}

event Locked(address indexed account, uint256 assets);
