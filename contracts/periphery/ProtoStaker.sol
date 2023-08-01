// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { WETH, ERC20, SafeTransferLib } from "solmate/src/tokens/WETH.sol";
import { AddressUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
  SafeERC20Upgradeable,
  IERC20PermitUpgradeable as IERC20Permit
} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { RewardsController, ClaimPermit } from "./../RewardsController.sol";

contract ProtoStaker is Initializable {
  using SafeERC20Upgradeable for IERC20Permit;
  using AddressUpgradeable for address;
  using FixedPointMathLib for uint256;
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
  /// @notice The gauge used to stake the liquidity pool tokens.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IGauge public immutable gauge;
  /// @notice Socket Gateway address.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  address public immutable socket;
  /// @notice Permit2 contract to be used to transfer assets from accounts.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPermit2 public immutable permit2;
  /// @notice The factory where the fee will be fetched from.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPoolFactory public immutable factory;
  /// @notice The rewards controller.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  RewardsController public immutable rewardsController;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    ERC20 exa_,
    WETH weth_,
    IGauge gauge_,
    IPoolFactory factory_,
    address socket_,
    IPermit2 permit2_,
    RewardsController rewardsController_
  ) {
    exa = exa_;
    weth = weth_;
    gauge = gauge_;
    socket = socket_;
    permit2 = permit2_;
    factory = factory_;
    rewardsController = rewardsController_;
    pool = factory_.getPool(exa_, weth_, false);

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize() external initializer {
    ERC20(address(pool)).safeApprove(address(gauge), type(uint256).max);
  }

  /// @notice Wraps or swaps `msg.value` ETH for EXA, adds liquidity and stakes liquidity on gauge.
  /// @param account The account to deposit the liquidity for.
  /// @param inEXA The amount of EXA to add liquidity with.
  /// @param minEXA The minimum amount of EXA to receive if msg.value is higher than needed.
  /// @param keepETH The amount of ETH to send to `account` (ex: for gas).
  function stake(address payable account, uint256 inEXA, uint256 minEXA, uint256 keepETH) internal {
    if (keepETH >= msg.value) return returnAssets(account, inEXA);

    uint256 inETH = msg.value - keepETH;
    uint256 reserveEXA;
    uint256 reserveWETH;
    {
      (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
      (reserveEXA, reserveWETH) = address(exa) < address(weth) ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    uint256 minETH = inEXA.mulDivDown(reserveWETH, reserveEXA);
    if (inETH < minETH) return returnAssets(account, inEXA);

    uint256 outEXA = 0;
    uint256 swapETH = 0;
    if (inETH > minETH) {
      swapETH = (inETH / 2).mulDivDown(inETH + reserveWETH, reserveWETH);
      outEXA = swapETH.mulDivDown(inEXA + reserveEXA, inETH + reserveWETH).mulDivDown(
        10_000 - factory.getFee(pool, false),
        10_000
      );
      if (outEXA + inEXA < minEXA) return returnAssets(account, inEXA);

      weth.deposit{ value: inETH }();
      weth.safeTransfer(address(pool), swapETH);
      (uint256 amount0Out, uint256 amount1Out) = address(exa) < address(weth)
        ? (outEXA, uint256(0))
        : (uint256(0), outEXA);
      pool.swap(amount0Out, amount1Out, this, "");
    } else {
      weth.deposit{ value: inETH }();
    }

    exa.safeTransfer(address(pool), inEXA + outEXA);
    weth.safeTransfer(address(pool), inETH - swapETH);
    gauge.deposit(pool.mint(this), account);

    if (keepETH != 0) account.safeTransferETH(keepETH);
  }

  /// @notice Transfer `msg.value` and `amountEXA` EXA back to `account`.
  /// @param account The account to transfer the assets to.
  /// @param amountEXA The amount of EXA to transfer.
  function returnAssets(address payable account, uint256 amountEXA) internal {
    account.safeTransferETH(msg.value);
    exa.safeTransfer(account, amountEXA);
  }

  /// @notice Swaps ~half of `msg.value` ETH for EXA, wraps the rest, adds liquidity and stakes liquidity on gauge.
  /// @param account The account to deposit the liquidity for.
  /// @param minEXA The minimum amount of EXA to receive.
  /// @param keepETH The amount of ETH to send to `account` (ex: for gas).
  function stakeETH(address payable account, uint256 minEXA, uint256 keepETH) external payable {
    stake(account, 0, minEXA, keepETH);
  }

  /// @notice Wraps `msg.value` ETH, adds liquidity with `p.value` EXA and stakes liquidity on gauge.
  /// @param inEXA The amount of EXA to transfer.
  /// @param minEXA The minimum amount of EXA to receive if msg.value is higher than needed.
  /// @param keepETH The amount of ETH to send to `account` (ex: for gas).
  function stakeBalance(address payable account, uint256 inEXA, uint256 minEXA, uint256 keepETH) public payable {
    exa.safeTransferFrom(account, address(this), inEXA);
    stake(account, inEXA, minEXA, keepETH);
  }

  /// @notice Wraps `msg.value` ETH, adds liquidity with `p.value` EXA and stakes liquidity on gauge.
  /// @param p The permit to use for the EXA transfer.
  /// @param minEXA The minimum amount of EXA to receive if msg.value is higher than needed.
  /// @param keepETH The amount of ETH to send to `account` (ex: for gas).
  function stakeBalance(Permit calldata p, uint256 minEXA, uint256 keepETH) external payable {
    IERC20Permit(address(exa)).safePermit(p.owner, address(this), p.value, p.deadline, p.v, p.r, p.s);
    stakeBalance(p.owner, p.value, minEXA, keepETH);
  }

  /// @notice Wraps `msg.value` ETH, adds liquidity with claimed EXA rewards and stakes liquidity on gauge.
  /// @param p The permit to use for the EXA claim.
  /// @param minEXA The minimum amount of EXA to receive if msg.value is higher than needed.
  /// @param keepETH The amount of ETH to send to `account` (ex: for gas).
  function stakeRewards(ClaimPermit calldata p, uint256 minEXA, uint256 keepETH) external payable {
    if (p.assets.length != 1 || address(p.assets[0]) != address(exa)) {
      return payable(p.owner).safeTransferETH(msg.value);
    }
    (, uint256[] memory claimedAmounts) = rewardsController.claim(rewardsController.allMarketsOperations(), p);
    if (claimedAmounts[0] == 0) return payable(p.owner).safeTransferETH(msg.value);
    stake(payable(p.owner), claimedAmounts[0], minEXA, keepETH);
  }

  function stakeAsset(ERC20 asset, uint256 amount, bytes calldata socketData, uint256 minEXA, uint256 keepETH) public {
    asset.safeTransferFrom(msg.sender, address(this), amount);
    asset.safeApprove(socket, amount);
    uint256 outETH = abi.decode(socket.functionCall(socketData), (uint256));
    this.stakeETH{ value: outETH }(payable(msg.sender), minEXA, keepETH);
  }

  function stakeAssetAndBalance(
    ERC20 asset,
    uint256 amount,
    bytes calldata socketData,
    uint256 inEXA,
    uint256 minEXA,
    uint256 keepETH
  ) public {
    asset.safeTransferFrom(msg.sender, address(this), amount);
    asset.safeApprove(socket, amount);
    uint256 outETH = abi.decode(socket.functionCall(socketData), (uint256));
    this.stakeBalance{ value: outETH }(payable(msg.sender), inEXA, minEXA, keepETH);
  }

  function stakeAsset(
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
    stakeAsset(asset, permit.value, socketData, minEXA, keepETH);
  }

  function stakeAssetAndBalance(
    ERC20 asset,
    Permit calldata permit,
    bytes calldata socketData,
    Permit calldata permitEXA,
    uint256 minEXA,
    uint256 keepETH
  ) external payable {
    IERC20Permit(address(asset)).safePermit(
      msg.sender,
      address(this),
      permit.value,
      permit.deadline,
      permit.v,
      permit.r,
      permit.s
    );
    stakeAssetAndBalance(asset, permit.value, socketData, permitEXA.value, minEXA, keepETH);
  }

  function stakeAsset(
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
    this.stakeETH{ value: outETH }(payable(msg.sender), minEXA, keepETH);
  }

  function stakeAssetAndBalance(
    ERC20 asset,
    Permit2 calldata permit,
    bytes calldata socketData,
    Permit calldata permitEXA,
    uint256 minEXA,
    uint256 keepETH
  ) external payable {
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
    this.stakeBalance{ value: outETH }(permitEXA, minEXA, keepETH);
  }

  /// @notice Returns the amount of ETH to pair with `amountEXA` to add liquidity.
  /// @param amountEXA The amount of EXA to add liquidity with.
  function previewETH(uint256 amountEXA) public view returns (uint256) {
    (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
    return
      address(exa) < address(weth)
        ? amountEXA.mulDivDown(reserve1, reserve0)
        : amountEXA.mulDivDown(reserve0, reserve1);
  }

  // solhint-disable-next-line no-empty-blocks
  receive() external payable {}
}

struct Permit {
  address payable owner;
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
    ProtoStaker to;
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

interface IPool is IERC20, IERC20Permit {
  function mint(ProtoStaker to) external returns (uint256 liquidity);

  function swap(uint256 amount0Out, uint256 amount1Out, ProtoStaker to, bytes calldata data) external;

  function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
}

interface IGauge is IERC20, IERC20Permit {
  function deposit(uint256 amount, address recipient) external;
}

interface IPoolFactory {
  function getFee(IPool pool, bool stable) external view returns (uint256);

  function getPool(ERC20 tokenA, ERC20 tokenB, bool stable) external view returns (IPool);
}
