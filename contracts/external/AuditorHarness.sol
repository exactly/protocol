// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/DecimalMath.sol";
import "../utils/MarketsLib.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract AuditorHarness {
    using DecimalMath for uint256;
    using MarketsLib for MarketsLib.Book;

    uint256 public blockNumber;
    address[] public marketAddresses;

    // Protocol Management
    MarketsLib.Book private book;

    function setBlockNumber(uint256 _blockNumber) public {
        blockNumber = _blockNumber;
    }

    function enableMarket(address fixedLender) public {
        MarketsLib.Market storage market = book.markets[fixedLender];
        market.isListed = true;

        marketAddresses.push(fixedLender);
    }
}
