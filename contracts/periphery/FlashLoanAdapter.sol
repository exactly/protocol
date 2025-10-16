// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import { AccessControl } from "@openzeppelin/contracts-v4/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts-v4/interfaces/IERC4626.sol";

contract FlashLoanAdapter is AccessControl {
  IBalancerVaultV3 public immutable vault;

  mapping(IERC20 wToken => bool isWToken) public isWToken;
  mapping(IERC20 asset => IERC4626 wToken) public wTokens;

  constructor(IBalancerVaultV3 vault_, address owner) {
    _grantRole(DEFAULT_ADMIN_ROLE, owner);
    vault = vault_;
  }

  function flashLoan(address recipient, IERC20[] memory tokens, uint256[] memory amounts, bytes memory data) external {
    assert(tokens.length == 1);
    assert(amounts.length == 1);
    uint256[] memory fees = new uint256[](1);
    if (tokens[0].balanceOf(address(vault)) < amounts[0]) {
      IERC4626 wToken = wTokens[tokens[0]];
      if (wToken == IERC4626(address(0)) || wToken.convertToAssets(wToken.balanceOf(address(vault))) < amounts[0]) {
        revert InsufficientLiquidity();
      }

      tokens[0] = IERC20(address(wToken));
      uint256 shares = wToken.previewWithdraw(amounts[0]);
      fees[0] = wToken.previewMint(shares) - amounts[0];
      amounts[0] = shares;
    }
    vault.unlock(
      abi.encodeWithSelector(this.receiveFlashLoan.selector, abi.encode(recipient, tokens, amounts, fees, data))
    );
  }

  function receiveFlashLoan(bytes calldata payload) external {
    if (msg.sender != address(vault)) revert UnauthorizedVault();
    (
      address recipient,
      IERC20[] memory tokens,
      uint256[] memory amounts,
      uint256[] memory fees,
      bytes memory data
    ) = abi.decode(payload, (address, IERC20[], uint256[], uint256[], bytes));

    if (isWToken[tokens[0]]) {
      IERC4626 wToken = IERC4626(address(tokens[0]));
      vault.sendTo(tokens[0], address(this), amounts[0]);
      tokens[0] = IERC20(wToken.asset());
      amounts[0] = wToken.redeem(amounts[0], recipient, address(this));
      IFlashLoanRecipient(recipient).receiveFlashLoan(tokens, amounts, fees, data);

      tokens[0].approve(address(wToken), amounts[0] + fees[0]);
      wToken.deposit(amounts[0] + fees[0], address(vault));
      vault.settle(wToken, amounts[0]);
    } else {
      vault.sendTo(tokens[0], recipient, amounts[0]);
      IFlashLoanRecipient(recipient).receiveFlashLoan(tokens, amounts, fees, data);
      tokens[0].transfer(address(vault), amounts[0]);
      vault.settle(tokens[0], amounts[0]);
    }
  }

  function setWToken(IERC20 asset, IERC4626 token) external onlyRole(DEFAULT_ADMIN_ROLE) {
    wTokens[asset] = token;
    isWToken[token] = true;
    emit WTokenSet(asset, token, msg.sender);
  }
}

interface IBalancerVaultV3 {
  function sendTo(IERC20 token, address to, uint256 amount) external;
  function settle(IERC20 token, uint256 amountHint) external returns (uint256 credit);
  function unlock(bytes calldata data) external returns (bytes memory);
}

interface IFlashLoanRecipient {
  function receiveFlashLoan(
    IERC20[] memory tokens,
    uint256[] memory amounts,
    uint256[] memory fees,
    bytes calldata data
  ) external;
}

error InsufficientLiquidity();
error UnauthorizedVault();

event WTokenSet(IERC20 indexed asset, IERC4626 indexed wToken, address indexed account);
