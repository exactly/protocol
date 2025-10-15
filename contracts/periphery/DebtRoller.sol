// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import { Initializable } from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/access/AccessControlUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/src/utils/SafeTransferLib.sol";

import { Auditor, Market, NotMarket } from "../Auditor.sol";

interface IFlashLoanRecipient {
  function receiveFlashLoan(
    IERC20[] memory tokens,
    uint256[] memory amounts,
    uint256[] memory fees,
    bytes memory data
  ) external;
}

contract DebtRoller is IFlashLoanRecipient, Initializable, AccessControlUpgradeable {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for address;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IFlashLoaner public immutable flashLoaner;
  bytes32 private callHash;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_, IFlashLoaner flashLoaner_) {
    auditor = auditor_;
    flashLoaner = flashLoaner_;

    _disableInitializers();
  }

  function initialize() external initializer {
    Market[] memory markets = auditor.allMarkets();
    for (uint256 i = 0; i < markets.length; ++i) approve(markets[i]);
  }

  function rollFixed(
    Market market,
    uint256 repayMaturity,
    uint256 borrowMaturity,
    uint256 maxRepayAssets,
    uint256 maxBorrowAssets,
    uint256 percentage
  ) external {
    _checkMarket(market);
    if (repayMaturity == borrowMaturity) revert InvalidOperation();

    RollFixedData memory data = RollFixedData({
      sender: msg.sender,
      market: market,
      repayMaturity: repayMaturity,
      borrowMaturity: borrowMaturity,
      maxRepayAssets: maxRepayAssets,
      maxBorrowAssets: maxBorrowAssets,
      percentage: percentage
    });

    IERC20[] memory tokens = new IERC20[](1);
    tokens[0] = IERC20(address(market.asset()));
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = maxRepayAssets;

    flashLoaner.flashLoan(address(this), tokens, amounts, _hash(abi.encode(data)));
  }

  function approve(Market market) public {
    _checkMarket(market);
    address(market.asset()).safeApprove(address(market), type(uint256).max);
  }

  function _hash(bytes memory data) internal returns (bytes memory) {
    callHash = keccak256(data);
    return data;
  }

  function receiveFlashLoan(IERC20[] memory, uint256[] memory, uint256[] memory fees, bytes memory data) external {
    bytes32 memCallHash = callHash;
    assert(msg.sender == address(flashLoaner) && memCallHash == keccak256(data));
    callHash = bytes32(0);

    RollFixedData memory r = abi.decode(data, (RollFixedData));
    (uint256 principal, uint256 fee) = r.market.fixedBorrowPositions(r.repayMaturity, r.sender);
    uint256 positionAssets = r.percentage < 1e18 ? r.percentage.mulWad(principal + fee) : principal + fee;

    uint256 actualRepay = r.market.repayAtMaturity(r.repayMaturity, positionAssets, r.maxRepayAssets, r.sender);
    uint256 cost = actualRepay + fees[0];
    r.market.borrowAtMaturity(r.borrowMaturity, cost, r.maxBorrowAssets, address(this), r.sender);

    address(r.market.asset()).safeTransfer(address(flashLoaner), r.maxRepayAssets + fees[0]);
  }

  function _checkMarket(Market market) internal view {
    (, , , bool listed, ) = auditor.markets(market);
    if (!listed) revert NotMarket();
  }
}

struct RollFixedData {
  address sender;
  Market market;
  uint256 repayMaturity;
  uint256 borrowMaturity;
  uint256 maxRepayAssets;
  uint256 maxBorrowAssets;
  uint256 percentage;
}

interface IFlashLoaner {
  function flashLoan(address recipient, IERC20[] memory tokens, uint256[] memory amounts, bytes memory data) external;
}

error InvalidOperation();
