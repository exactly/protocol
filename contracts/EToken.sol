// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IEToken, AlreadyInitialized, SmartPoolFundsLocked } from "./interfaces/IEToken.sol";
import { IFixedLender, NotFixedLender } from "./interfaces/IFixedLender.sol";
import { IAuditor } from "./interfaces/IAuditor.sol";

contract EToken is IEToken, AccessControl {
  // totalSupply = smart pool's balance
  uint256 public override totalSupply;
  // index = totalSupply / totalScaledBalance
  uint256 private totalScaledBalance;
  // userBalance = userScaledBalance * index
  mapping(address => uint256) private userScaledBalance;
  mapping(address => uint256) private lastBalanceIncrease;

  mapping(address => mapping(address => uint256)) private _allowances;
  string public override name;
  string public override symbol;
  uint8 public immutable override decimals;

  IFixedLender public immutable fixedLender;
  IAuditor public immutable auditor;

  modifier onlyFixedLender() {
    if (msg.sender != address(fixedLender)) revert NotFixedLender();
    _;
  }

  constructor(
    string memory _name,
    string memory _symbol,
    uint8 _decimals,
    IFixedLender _fixedLender,
    IAuditor _auditor
  ) {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

    name = _name;
    symbol = _symbol;
    decimals = _decimals;
    fixedLender = _fixedLender;
    auditor = _auditor;
  }

  /// @dev Mints `amount` eTokens to `user`. Only callable by the FixedLender.
  /// @param user The address receiving the minted tokens.
  /// @param amount The amount of tokens getting minted.
  function mint(address user, uint256 amount) external override onlyFixedLender {
    require(user != address(0), "ERC20: zero address");

    uint256 scaledBalance = amount;
    if (totalSupply != 0) scaledBalance = (scaledBalance * totalScaledBalance) / totalSupply;

    userScaledBalance[user] += scaledBalance;
    totalScaledBalance += scaledBalance;
    totalSupply += amount;
    lastBalanceIncrease[user] = block.number;

    emit Transfer(address(0), user, amount);
  }

  /// @dev Increases contract earnings. Only callable by the FixedLender.
  /// @param amount The amount of underlying tokens deposited.
  function accrueEarnings(uint256 amount) external override onlyFixedLender {
    totalSupply += amount;
    emit EarningsAccrued(amount);
  }

  /// @dev Burns eTokens from `user`. Only callable by the FixedLender.
  /// @param user The owner of the eTokens, getting them burned.
  /// @param amount The amount being burned.
  function burn(address user, uint256 amount) external override onlyFixedLender {
    require(user != address(0), "ERC20: zero address");

    if (lastBalanceIncrease[user] >= block.number) revert SmartPoolFundsLocked();

    require(balanceOf(user) >= amount, "ERC20: balance exceeded");

    uint256 scaledWithdrawAmount = (amount * totalScaledBalance) / totalSupply;

    totalScaledBalance -= scaledWithdrawAmount;
    userScaledBalance[user] -= scaledWithdrawAmount;
    totalSupply -= amount;

    emit Transfer(user, address(0), amount);
  }

  /// @dev Initializes the eToken setting the FixedLender and Auditor addresses. Only able to initialize once.
  /// @param fixedLender_ The address of the FixedLender that uses this eToken.
  /// @param auditor_ The address of the Auditor.
  function initialize(IFixedLender fixedLender_, IAuditor auditor_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (address(fixedLender) != address(0) && address(auditor) != address(0)) revert AlreadyInitialized();
    emit Initialized(fixedLender_, auditor_);
  }

  /// @dev Executes a transfer of tokens from msg.sender to recipient.
  /// @param recipient The recipient of the tokens.
  /// @param amount The amount of tokens being transferred.
  /// @return `true` if the transfer succeeds, reverts otherwise.
  function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
    _transfer(msg.sender, recipient, amount);
    return true;
  }

  /// @dev Executes a transfer of token from sender to recipient, if msg.sender is allowed to do so.
  /// @param sender The owner of the tokens.
  /// @param recipient The recipient of the tokens.
  /// @param amount The amount of tokens being transferred.
  /// @return `true` if the transfer succeeds, reverts otherwise.
  function transferFrom(
    address sender,
    address recipient,
    uint256 amount
  ) public virtual override returns (bool) {
    _transfer(sender, recipient, amount);

    uint256 currentAllowance = _allowances[sender][msg.sender];
    require(currentAllowance >= amount, "ERC20: allowance exceeded");
    unchecked {
      _approve(sender, msg.sender, currentAllowance - amount);
    }

    return true;
  }

  /// @dev Allows `spender` to spend the tokens owned by msg.sender.
  /// @param spender The user allowed to spend msg.sender tokens.
  /// @param amount The amount of tokens spender is allowed to spend.
  /// @return `true` if the reverts succeeds, reverts otherwise.
  function approve(address spender, uint256 amount) public virtual override returns (bool) {
    _approve(msg.sender, spender, amount);
    return true;
  }

  /// @dev Increases the allowance of spender to spend msg.sender tokens.
  /// @param spender The user allowed to spend on behalf of msg.sender.
  /// @param addedValue The amount being added to the allowance.
  /// @return `true` if the increase allowance succeeds, reverts otherwise.
  function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
    _approve(msg.sender, spender, _allowances[msg.sender][spender] + addedValue);
    return true;
  }

  /// @dev Decreases the allowance of spender to spend msg.sender tokens.
  /// @param spender The user allowed to spend on behalf of msg.sender.
  /// @param subtractedValue The amount being subtracted to the allowance.
  /// @return `true` if the decrease allowance succeeds, reverts otherwise.
  function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
    uint256 currentAllowance = _allowances[msg.sender][spender];
    require(currentAllowance >= subtractedValue, "ERC20: allowance underflow");
    unchecked {
      _approve(msg.sender, spender, currentAllowance - subtractedValue);
    }

    return true;
  }

  /// @dev Calculates the balance of the user: principal balance + interest generated by the principal.
  /// @param account The user whose balance is calculated.
  /// @return The balance of the user.
  function balanceOf(address account) public view override returns (uint256) {
    if (userScaledBalance[account] == 0) return 0;

    return (userScaledBalance[account] * totalSupply) / totalScaledBalance;
  }

  /// @dev Returns the allowance of spender on the tokens owned by owner.
  /// @param owner The owner of the tokens.
  /// @param spender The user allowed to spend the owner's tokens.
  /// @return The amount of owner's tokens spender is allowed to spend.
  function allowance(address owner, address spender) public view virtual override returns (uint256) {
    return _allowances[owner][spender];
  }

  /// @dev Moves `amount` of tokens from `sender` to `recipient`.
  /// @param sender The sender of the tokens.
  /// @param recipient The recipient of the tokens.
  /// @param amount The amount of tokens being transferred.
  function _transfer(
    address sender,
    address recipient,
    uint256 amount
  ) internal virtual {
    require(sender != address(0), "ERC20: zero address");
    require(recipient != address(0), "ERC20: zero address");

    uint256 senderBalance = balanceOf(sender);
    require(senderBalance >= amount, "ERC20: balance exceeded");
    // reverts on failure
    auditor.validateAccountShortfall(fixedLender, sender, amount);

    uint256 senderRemainingBalance = senderBalance - amount;
    userScaledBalance[sender] = (senderRemainingBalance * totalScaledBalance) / totalSupply;
    userScaledBalance[recipient] = ((balanceOf(recipient) + amount) * totalScaledBalance) / totalSupply;
    lastBalanceIncrease[recipient] = block.number;

    emit Transfer(sender, recipient, amount);
  }

  /// @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
  /// @param owner The owner of the tokens.
  /// @param spender The user allowed to spend owner tokens.
  /// @param amount The amount of owner's tokens spender is allowed to spend.
  function _approve(
    address owner,
    address spender,
    uint256 amount
  ) internal virtual {
    require(owner != address(0), "ERC20: zero address");
    require(spender != address(0), "ERC20: zero address");

    _allowances[owner][spender] = amount;
    emit Approval(owner, spender, amount);
  }
}
