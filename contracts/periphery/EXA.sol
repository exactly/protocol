// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/access/AccessControlUpgradeable.sol";
import {
  ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { StorageSlotUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/utils/StorageSlotUpgradeable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC7802 } from "@openzeppelin/contracts/interfaces/draft-IERC7802.sol";

contract EXA is ERC20VotesUpgradeable, AccessControlUpgradeable, IERC7802 {
  bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
  bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize() external initializer {
    __ERC20_init("exactly", "EXA");
    __ERC20Permit_init("exactly");
    __ERC20Votes_init();
    if (block.chainid == 10) _mint(msg.sender, 10_000_000e18);
  }

  function initialize2(address admin_) external reinitializer(2) {
    if (msg.sender != StorageSlotUpgradeable.getAddressSlot(ADMIN_SLOT).value) revert NotProxyAdmin();
    if (admin_ == address(0)) revert ZeroAddress();

    __AccessControl_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin_);
  }

  /// @inheritdoc IERC7802
  function crosschainMint(address to, uint256 amount) public onlyRole(BRIDGE_ROLE) {
    _mint(to, amount);
    emit CrosschainMint(to, amount, msg.sender);
  }

  /// @inheritdoc IERC7802
  function crosschainBurn(address from, uint256 amount) public onlyRole(BRIDGE_ROLE) {
    _burn(from, amount);
    emit CrosschainBurn(from, amount, msg.sender);
  }

  function mint(address to, uint256 amount) external {
    crosschainMint(to, amount);
  }

  function burn(address from, uint256 amount) external {
    crosschainBurn(from, amount);
  }

  function clock() public view override returns (uint48) {
    return uint48(block.timestamp);
  }

  // solhint-disable-next-line func-name-mixedcase
  function CLOCK_MODE() public pure override returns (string memory) {
    return "mode=timestamp";
  }

  function supportsInterface(
    bytes4 interfaceId
  ) public view override(AccessControlUpgradeable, IERC165) returns (bool) {
    return interfaceId == type(IERC7802).interfaceId || super.supportsInterface(interfaceId);
  }
}

error NotProxyAdmin();
error ZeroAddress();
