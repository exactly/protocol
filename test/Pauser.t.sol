// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0; // solhint-disable-line one-contract-per-file

import { Test, stdError } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { Auditor } from "../contracts/Auditor.sol";
import { Market, InterestRateModel } from "../contracts/Market.sol";
import { MockInterestRateModel } from "../contracts/mocks/MockInterestRateModel.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import { Pauser, Ownable, IPausable } from "../contracts/periphery/Pauser.sol";

contract PauserTest is Test {
  Auditor internal auditor;
  Market internal marketA;
  Market internal marketB;
  Pauser internal pauser;

  address internal constant BOB = address(0xb0b);

  function setUp() external {
    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    vm.label(address(auditor), "Auditor");

    pauser = new Pauser(auditor, address(this));

    MockInterestRateModel irm = new MockInterestRateModel(0.1e18);

    marketA = Market(address(new ERC1967Proxy(address(new Market(new MockERC20("A", "A", 18), auditor)), "")));
    marketA.initialize(
      "A",
      3,
      1e18,
      InterestRateModel(address(irm)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    marketA.setDampSpeed(
      marketA.floatingAssetsDampSpeedUp(),
      marketA.floatingAssetsDampSpeedDown(),
      0.23e18,
      0.000053e18
    );
    marketA.setFixedBorrowThreshold(1e18);
    marketA.grantRole(marketA.PAUSER_ROLE(), address(this));
    marketA.grantRole(marketA.PAUSER_ROLE(), address(pauser));
    auditor.enableMarket(marketA, new MockPriceFeed(18, 1e18), 0.8e18);
    vm.label(address(marketA), "MarketA");

    marketB = Market(address(new ERC1967Proxy(address(new Market(new MockERC20("B", "B", 18), auditor)), "")));
    marketB.initialize(
      "B",
      3,
      1e18,
      InterestRateModel(address(irm)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    marketB.setDampSpeed(
      marketB.floatingAssetsDampSpeedUp(),
      marketB.floatingAssetsDampSpeedDown(),
      0.23e18,
      0.000053e18
    );
    marketB.setFixedBorrowThreshold(1e18);
    marketB.grantRole(marketB.PAUSER_ROLE(), address(this));
    marketB.grantRole(marketB.PAUSER_ROLE(), address(pauser));
    auditor.enableMarket(marketB, new MockPriceFeed(18, 1e18), 0.8e18);
    vm.label(address(marketB), "MarketB");

    vm.label(BOB, "bob");
  }

  function testPauseProtocolWhenMarketsAreUnpaused() external {
    pauser.pauseProtocol(new IPausable[](0));

    assertTrue(marketA.paused());
    assertTrue(marketB.paused());
  }

  function testPauseProtocolWhenOneMarketIsPaused() external {
    marketA.pause();

    pauser.pauseProtocol(new IPausable[](0));

    assertTrue(marketA.paused());
    assertTrue(marketB.paused());
  }

  function testPauseProtocolWhenMarketsArePaused() external {
    marketA.pause();
    marketB.pause();

    vm.expectRevert(stdError.assertionError);
    pauser.pauseProtocol(new IPausable[](0));
  }

  function testPauseProtocolFromRando() external {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
    vm.prank(BOB);
    pauser.pauseProtocol(new IPausable[](0));
  }

  function testPauseProtocolWithExtra() external {
    IPausable[] memory extra = new IPausable[](1);
    extra[0] = new Pausable();

    pauser.pauseProtocol(extra);

    assertTrue(marketA.paused());
    assertTrue(marketB.paused());
    assertTrue(extra[0].paused());
  }

  function testPauseTargets() external {
    IPausable[] memory targets = new IPausable[](3);
    for (uint256 i = 0; i < targets.length; ++i) targets[i] = new Pausable();

    pauser.pause(targets);

    assertFalse(marketA.paused());
    assertFalse(marketB.paused());
    for (uint256 i = 0; i < targets.length; ++i) assertTrue(targets[i].paused());
  }

  function testPauseTargetsAlreadyPaused() external {
    IPausable[] memory targets = new IPausable[](3);
    for (uint256 i = 0; i < targets.length; ++i) {
      targets[i] = new Pausable();
      targets[i].pause();
    }

    vm.expectRevert(stdError.assertionError);
    pauser.pause(targets);
  }
}

contract Pausable is IPausable {
  bool internal paused_;

  function paused() external view override returns (bool) {
    return paused_;
  }

  function pause() external override {
    paused_ = true;
  }
}
