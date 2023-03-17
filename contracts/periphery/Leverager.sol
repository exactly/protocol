// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { Auditor, MarketNotListed } from "../Auditor.sol";
import { Market } from "../Market.sol";

contract Leverager {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;

  IBalancerVault public immutable balancerVault;
  Auditor public immutable auditor;

  constructor(Auditor auditor_, IBalancerVault balancerVault_) {
    auditor = auditor_;
    balancerVault = balancerVault_;
  }

  function leverage(Market market, uint256 principal, uint256 targetHealthFactor, bool deposit) external {
    ERC20 asset = market.asset();
    if (deposit) {
      asset.safeTransferFrom(msg.sender, address(this), principal);
    }

    (uint256 adjustedFactor, , , , ) = auditor.markets(market);
    uint256 factor = adjustedFactor.mulWadDown(adjustedFactor).divWadDown(targetHealthFactor);

    ERC20[] memory tokens = new ERC20[](1);
    tokens[0] = asset;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = principal.mulWadDown(factor).divWadDown(1e18 - factor);
    balancerVault.flashLoan(
      address(this),
      tokens,
      amounts,
      abi.encode(
        FlashloanCallback({
          market: market,
          account: msg.sender,
          principal: principal,
          leverage: true,
          deposit: deposit
        })
      )
    );
  }

  function deleverage(Market market, uint256 percentage) external {
    (, , uint256 floatingBorrowShares) = market.accounts(msg.sender);

    ERC20[] memory tokens = new ERC20[](1);
    tokens[0] = market.asset();
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = market.previewRefund(floatingBorrowShares.mulWadDown(percentage));
    balancerVault.flashLoan(
      address(this),
      tokens,
      amounts,
      abi.encode(
        FlashloanCallback({ market: market, account: msg.sender, principal: 0, leverage: false, deposit: false })
      )
    );
  }

  function receiveFlashLoan(
    ERC20[] memory,
    uint256[] memory amounts,
    uint256[] memory,
    bytes memory userData
  ) external {
    if (msg.sender != address(balancerVault)) revert NotBalancerVault();

    FlashloanCallback memory f = abi.decode(userData, (FlashloanCallback));
    if (f.leverage) {
      if (f.deposit) {
        f.market.deposit(amounts[0] + f.principal, f.account);
      } else {
        f.market.deposit(amounts[0], f.account);
      }
      f.market.borrow(amounts[0], address(balancerVault), f.account);
    } else {
      f.market.repay(amounts[0], f.account);
      f.market.withdraw(amounts[0], address(balancerVault), f.account);
    }
  }

  function approve(Market market) external {
    (, , , bool isListed, ) = auditor.markets(market);
    if (!isListed) revert MarketNotListed();

    market.asset().approve(address(market), type(uint256).max);
  }
}

error NotBalancerVault();

struct FlashloanCallback {
  Market market;
  address account;
  uint256 principal;
  bool leverage;
  bool deposit;
}

interface IBalancerVault {
  function flashLoan(
    address recipient,
    ERC20[] memory tokens,
    uint256[] memory amounts,
    bytes memory userData
  ) external;
}
