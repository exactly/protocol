// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { DateTime } from "@quant-finance/solidity-datetime/contracts/DateTime.sol";
import { AccessControl, IAccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC721Metadata, IERC165, IERC721 } from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import { ERC721TokenReceiver } from "@rari-capital/solmate/src/tokens/ERC721.sol";
import { FixedLender } from "./FixedLender.sol";
import { Auditor } from "./Auditor.sol";
import { PoolLib } from "./utils/PoolLib.sol";
import { TSUtils } from "./utils/TSUtils.sol";

contract MaturityPositions is AccessControl, IERC721Metadata {
  using DateTime for uint256;
  using PoolLib for uint256;
  using Strings for uint256;
  using Base64 for bytes;

  Auditor public immutable auditor;

  string public name = "Exactly Maturity Positions";

  string public symbol = "EXAMP";

  mapping(string => string) public logos;

  constructor(Auditor auditor_) {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    auditor = auditor_;
  }

  function balanceOf(address owner) external view returns (uint256 balance) {
    if (owner == address(0)) revert NotFound();

    unchecked {
      FixedLender[] memory markets = auditor.getAllMarkets();
      for (uint256 m = 0; m < markets.length; ++m) {
        uint256 packedSupplied = markets[m].userMpSupplied(owner) >> 32;
        uint256 packedBorrowed = markets[m].userMpBorrowed(owner) >> 32;
        for (uint256 i = 0; i < 224; ++i) {
          if ((packedSupplied & (1 << i)) != 0) ++balance;
          if ((packedBorrowed & (1 << i)) != 0) ++balance;
          if ((1 << i) > packedSupplied && (1 << i) > packedBorrowed) break;
        }
      }
    }
  }

  function ownerOf(uint256 id) external view returns (address owner) {
    owner = address(uint160(id & ((1 << 160) - 1)));
    uint256 maturity = uint32(id >> 160);
    uint256 index = uint8(id >> 192);
    bool debt = (id & (1 << 200)) != 0;

    FixedLender fixedLender = auditor.allMarkets(index);
    if (!(debt ? fixedLender.userMpBorrowed(owner) : fixedLender.userMpSupplied(owner)).hasMaturity(maturity)) {
      revert NotFound();
    }
  }

  function tokenURI(uint256 id) external view returns (string memory) {
    address owner = address(uint160(id & ((1 << 160) - 1)));
    uint256 maturity = uint32(id >> 160);
    bool debt = (id & (1 << 200)) != 0;
    FixedLender fixedLender = auditor.allMarkets(uint8(id >> 192));

    if (!(debt ? fixedLender.userMpBorrowed(owner) : fixedLender.userMpSupplied(owner)).hasMaturity(maturity)) {
      revert NotFound();
    }

    string memory assetSymbol = fixedLender.assetSymbol();
    (uint256 year, uint256 month, uint256 day) = maturity.timestampToDate();
    uint256 amount;
    if (debt) amount = fixedLender.getAccountBorrows(owner, maturity);
    else {
      (uint256 principal, uint256 fee) = fixedLender.mpUserSuppliedAmount(maturity, owner);
      amount = principal + fee;
    }
    uint256 amountDecimal = (amount % 1e18) / 1e16;

    // solhint-disable max-line-length
    return
      string.concat(
        "data:application/json;base64,",
        abi
          .encodePacked(
            '{"name":"',
            string.concat("Exactly - ", assetSymbol),
            '", "description":"',
            string.concat(assetSymbol, " maturity position"),
            '", "image": "',
            "data:image/svg+xml;base64,",
            abi
              .encodePacked(
                '<svg width="512" height="128" viewBox="0 0 224 56" xmlns="http://www.w3.org/2000/svg">'
                '<circle cx="28" cy="28" r="28" fill="url(#paint0_linear)"></circle>'
                '<path d="M39.0463 45.2494C39.0358 45.2588 39.0251 45.2681 39.0142 45.2772C38.4638 45.7376 37.5969 45.7002 37.136 45.1505L26.9849 32.9826C26.524 32.4328 26.5614 31.5418 27.1118 31.0813C27.6622 30.6209 28.5542 30.6583 29.0151 31.2081L36.9511 40.794V34.6155L29.3958 25.2309C28.9348 24.6811 28.8454 23.7478 29.3958 23.2874C29.9033 22.7804 31.0496 22.7376 31.5106 23.2874C31.9715 23.8372 36.9511 30.5708 36.9511 30.5708L36.8996 24.4515L26.96 12.6217C26.4991 12.0719 26.5891 11.1571 27.1395 10.6967C27.6899 10.2363 28.5965 10.3363 29.0574 10.8861L39.0144 22.9306C39.063 22.9885 39.1891 23.1209 39.2259 23.1841C39.3811 23.3979 39.522 23.7024 39.522 23.9868V44.2243C39.522 44.6422 39.3528 44.9758 39.0463 45.2494Z" fill="#A6A6F4"></path>'
                '<path d="M16.9237 45.2494C16.9342 45.2588 16.9449 45.2681 16.9558 45.2772C17.5062 45.7376 18.3731 45.7002 18.834 45.1505L28.9849 32.9826C29.4459 32.4328 29.4084 31.5418 28.8581 31.0813C28.3077 30.6209 27.4157 30.6583 26.9548 31.2081L19.0189 40.794V34.6155L26.5741 25.2309C27.035 24.6811 27.1245 23.7478 26.5741 23.2874C26.0666 22.7804 24.9203 22.7376 24.4593 23.2874C23.9984 23.8372 19.0189 30.5708 19.0189 30.5708L19.0704 24.4515L29.0098 12.6217C29.4707 12.0719 29.3808 11.1571 28.8304 10.6967C28.28 10.2363 27.3734 10.3363 26.9125 10.8861L16.9556 22.9306C16.907 22.9885 16.7809 23.1209 16.7441 23.1841C16.5889 23.3979 16.448 23.7024 16.448 23.9868V44.2243C16.448 44.6422 16.6172 44.9758 16.9237 45.2494Z" fill="white"></path>'
                "<defs>"
                '  <linearGradient id="paint0_linear" x1="56" y1="28.0001" x2="-8.05155e-7" y2="28" gradientUnits="userSpaceOnUse">'
                '    <stop stop-color="#4D4DE8"></stop>'
                '    <stop offset="1" stop-color="#7BF5E1"></stop>'
                "  </linearGradient>"
                "</defs>"
                '<text x="60" y="13">',
                assetSymbol,
                "</text>"
                '<text x="60" y="33">',
                string.concat(
                  year.toString(),
                  "-",
                  month < 10 ? "0" : "",
                  month.toString(),
                  "-",
                  day < 10 ? "0" : "",
                  day.toString()
                ),
                "</text>"
                '<text x="60" y="53">',
                string.concat(
                  debt ? "-" : "",
                  (amount / 1e18).toString(),
                  ".",
                  amountDecimal < 10 ? "0" : "",
                  amountDecimal.toString()
                ),
                "</text>"
                "</svg>"
              )
              .encode(),
            '"}'
          )
          .encode()
      );
    // solhint-enable max-line-length
  }

  function setLogo(string calldata assetSymbol, string calldata logo) external onlyRole(DEFAULT_ADMIN_ROLE) {
    logos[assetSymbol] = logo;
  }

  function getApproved(uint256) external pure returns (address) {
    return address(0);
  }

  function isApprovedForAll(address, address) external pure returns (bool) {
    return false;
  }

  function approve(address, uint256) public pure {
    revert Unsupported();
  }

  function setApprovalForAll(address, bool) public pure {
    revert Unsupported();
  }

  function transferFrom(
    address,
    address,
    uint256
  ) public pure {
    revert Unsupported();
  }

  function safeTransferFrom(
    address,
    address,
    uint256
  ) public pure {
    revert Unsupported();
  }

  function safeTransferFrom(
    address,
    address,
    uint256,
    bytes memory
  ) public pure {
    revert Unsupported();
  }

  function supportsInterface(bytes4 interfaceId) public pure override(AccessControl, IERC165) returns (bool) {
    return
      interfaceId == type(IAccessControl).interfaceId ||
      interfaceId == type(IERC721Metadata).interfaceId ||
      interfaceId == type(IERC721).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }
}

error NotFound();
error Unsupported();
