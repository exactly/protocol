// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { WETH, ERC20 } from "solmate/src/tokens/WETH.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { AddressUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {
  SafeERC20Upgradeable,
  IERC20PermitUpgradeable as IERC20Permit
} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

contract Swapper {
  using SafeERC20Upgradeable for IERC20Permit;
  using AddressUpgradeable for address;
  using SafeTransferLib for address payable;
  using SafeTransferLib for ERC20;
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
  /// @notice Socket Gateway address.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  address public immutable socket;
  /// @notice Permit2 contract to be used to transfer assets from accounts.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPermit2 public immutable permit2;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(ERC20 exa_, WETH weth_, IPool pool_, address socket_, IPermit2 permit2_) {
    exa = exa_;
    weth = weth_;
    pool = pool_;
    socket = socket_;
    permit2 = permit2_;
  }

  /// @notice Swaps `msg.value` ETH for EXA and sends it to `account`.
  /// @param account The account to send the EXA to.
  /// @param minEXA The minimum amount of EXA to receive.
  /// @param keepETH The amount of ETH to send to `account` (ex: for gas).
  function swap(address payable account, uint256 minEXA, uint256 keepETH) external payable {
    if (keepETH >= msg.value) return account.safeTransferETH(msg.value);

    uint256 inETH = msg.value - keepETH;
    uint256 outEXA = pool.getAmountOut(inETH, weth);
    if (outEXA < minEXA) return account.safeTransferETH(msg.value);

    weth.deposit{ value: inETH }();
    weth.safeTransfer(address(pool), inETH);

    (uint256 amount0Out, uint256 amount1Out) = address(exa) < address(weth)
      ? (outEXA, uint256(0))
      : (uint256(0), outEXA);
    pool.swap(amount0Out, amount1Out, account, "");

    if (keepETH != 0) account.safeTransferETH(keepETH);
  }

  function swap(ERC20 asset, uint256 amount, bytes calldata socketData, uint256 minEXA, uint256 keepETH) public {
    asset.safeTransferFrom(msg.sender, address(this), amount);
    asset.safeApprove(socket, amount);
    uint256 outETH = abi.decode(socket.functionCall(socketData), (uint256));
    this.swap{ value: outETH }(payable(msg.sender), minEXA, keepETH);
  }

  function swap(
    ERC20 asset,
    Permit calldata permit,
    bytes calldata socketData,
    uint256 minEXA,
    uint256 keepETH
  ) external {
    IERC20Permit(address(asset)).safePermit(
      msg.sender,
      address(this),
      permit.value,
      permit.deadline,
      permit.v,
      permit.r,
      permit.s
    );
    swap(asset, permit.value, socketData, minEXA, keepETH);
  }

  function swap(
    ERC20 asset,
    Permit2 calldata permit,
    bytes calldata socketData,
    uint256 minEXA,
    uint256 keepETH
  ) external {
    permit2.permitTransferFrom(
      IPermit2.PermitTransferFrom({
        permitted: IPermit2.TokenPermissions(asset, permit.amount),
        nonce: uint256(keccak256(abi.encode(msg.sender, asset, permit.amount, permit.deadline))),
        deadline: permit.deadline
      }),
      IPermit2.SignatureTransferDetails({ to: this, requestedAmount: permit.amount }),
      msg.sender,
      permit.signature
    );
    asset.safeApprove(socket, permit.amount);
    uint256 outETH = abi.decode(socket.functionCall(socketData), (uint256));
    this.swap{ value: outETH }(payable(msg.sender), minEXA, keepETH);
  }

  // solhint-disable-next-line no-empty-blocks
  receive() external payable {}
}

struct Permit {
  uint256 value;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}

struct Permit2 {
  uint256 amount;
  uint256 deadline;
  bytes signature;
}

interface IPermit2 {
  struct TokenPermissions {
    ERC20 token;
    uint256 amount;
  }

  struct PermitTransferFrom {
    TokenPermissions permitted;
    uint256 nonce;
    uint256 deadline;
  }

  struct SignatureTransferDetails {
    Swapper to;
    uint256 requestedAmount;
  }

  function permitTransferFrom(
    PermitTransferFrom memory permit,
    SignatureTransferDetails calldata transferDetails,
    address owner,
    bytes calldata signature
  ) external;

  // solhint-disable-next-line func-name-mixedcase
  function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IPool {
  function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

  function getAmountOut(uint256 amountIn, WETH tokenIn) external view returns (uint256);
}
