// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "@rari-capital/solmate/src/test/utils/mocks/MockERC20.sol";
import { MaturityPositions, NotFound, Unsupported } from "../../contracts/MaturityPositions.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";
import { FixedLender } from "../../contracts/FixedLender.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { Auditor } from "../../contracts/Auditor.sol";

contract MaturityPositionsTest is Test {
  address internal constant MAX = address(type(uint160).max);
  address internal constant BOB = address(0x69);

  MaturityPositions internal positions;
  FixedLender internal fixedLenderDAI;
  FixedLender internal fixedLenderYAY;

  function setUp() external {
    MockERC20 dai = new MockERC20("DAI", "DAI", 18);
    MockERC20 yay = new MockERC20("YAY", "YAY", 18);
    MockInterestRateModel irm = new MockInterestRateModel(0);
    MockOracle mockOracle = new MockOracle();
    Auditor auditor = new Auditor(mockOracle, 0);
    fixedLenderDAI = new FixedLender(dai, "DAI", 12, 1e18, auditor, irm, 0, 0);
    fixedLenderYAY = new FixedLender(yay, "YAY", 12, 1e18, auditor, irm, 0, 0);
    positions = new MaturityPositions(auditor);

    mockOracle.setPrice("DAI", 1e8);
    mockOracle.setPrice("YAY", 1e8);
    auditor.enableMarket(fixedLenderDAI, 1e18, "DAI", "DAI", 18);
    auditor.enableMarket(fixedLenderYAY, 1e18, "YAY", "YAY", 18);

    FixedLender[] memory markets = new FixedLender[](2);
    markets[0] = fixedLenderDAI;
    markets[1] = fixedLenderYAY;

    vm.label(MAX, "max");
    vm.label(BOB, "bob");

    vm.startPrank(MAX);
    dai.mint(MAX, 420 ether);
    yay.mint(MAX, 420 ether);
    dai.approve(address(fixedLenderDAI), type(uint256).max);
    yay.approve(address(fixedLenderYAY), type(uint256).max);
    auditor.enterMarkets(markets);
    fixedLenderYAY.deposit(69 ether, MAX);
    fixedLenderDAI.depositAtMaturity(7 days, 69 ether, 69 ether, MAX);
    fixedLenderYAY.borrowAtMaturity(14 days, 69 ether, 69 ether, MAX, MAX);
    vm.stopPrank();

    vm.startPrank(BOB);
    dai.mint(BOB, 420 ether);
    dai.approve(address(fixedLenderDAI), type(uint256).max);
    auditor.enterMarkets(markets);
    fixedLenderDAI.deposit(420 ether, BOB);
    fixedLenderDAI.borrowAtMaturity(7 days, 69 ether, 69 ether, BOB, BOB);
    vm.stopPrank();
  }

  function testOwnerOf() external {
    assertEq(positions.ownerOf(toId(MAX, 7 days, 0, false)), MAX);
    assertEq(positions.ownerOf(toId(BOB, 7 days, 0, true)), BOB);
    assertEq(positions.ownerOf(toId(MAX, 14 days, 1, true)), MAX);

    vm.expectRevert(NotFound.selector);
    positions.ownerOf(0);
    vm.expectRevert(NotFound.selector);
    positions.ownerOf(toId(MAX, 7 days, 0, true));
    vm.expectRevert(NotFound.selector);
    positions.ownerOf(toId(MAX, 7 days, 1, false));
    vm.expectRevert(NotFound.selector);
    positions.ownerOf(toId(MAX, 14 days, 0, false));
    vm.expectRevert(NotFound.selector);
    positions.ownerOf(toId(BOB, 7 days, 0, false));
    vm.expectRevert();
    positions.ownerOf(toId(MAX, 7 days, 2, false));
  }

  function testBalanceOf() external {
    assertEq(positions.balanceOf(MAX), 2);
    assertEq(positions.balanceOf(BOB), 1);

    vm.prank(MAX);
    fixedLenderDAI.depositAtMaturity(14 days, 69 ether, 69 ether, MAX);
    assertEq(positions.balanceOf(MAX), 3);

    vm.prank(BOB);
    fixedLenderDAI.repayAtMaturity(7 days, 69 ether, 69 ether, BOB);
    assertEq(positions.balanceOf(BOB), 0);

    vm.expectRevert(NotFound.selector);
    positions.balanceOf(address(0));
  }

  function testTokenURI() external {
    emit log(positions.tokenURI(toId(MAX, 7 days, 0, false)));
    vm.expectRevert(NotFound.selector);
    positions.tokenURI(0);
  }

  function testUnsupported() external {
    vm.expectRevert(Unsupported.selector);
    positions.approve(BOB, 0);
    vm.expectRevert(Unsupported.selector);
    positions.setApprovalForAll(BOB, true);
    vm.expectRevert(Unsupported.selector);
    positions.transferFrom(MAX, BOB, 0);
    vm.expectRevert(Unsupported.selector);
    positions.safeTransferFrom(MAX, BOB, 0);
    vm.expectRevert(Unsupported.selector);
    positions.safeTransferFrom(MAX, BOB, 0, "");
  }

  function toId(
    address owner,
    uint256 maturity,
    uint256 index,
    bool debt
  ) internal pure returns (uint256) {
    return (debt ? 1 << 200 : 0) | (index << 192) | (maturity << 160) | uint160(owner);
  }
}
