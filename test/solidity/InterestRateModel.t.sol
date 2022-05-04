// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";

contract InterestRateModelTest is Test, InterestRateModel(3.75e16, 0.75e16, 3e18, 2e18, 0) {
  function testReferenceRate(uint256 v0, uint64 delta) external {
    uint256 u0 = v0 % fullUtilization;
    uint256 u1 = u0 + (delta % (maxUtilization - u0));

    string[] memory ffi = new string[](2);
    ffi[0] = "ffi/irm";
    ffi[1] = encodeHex(abi.encode(u0, u1, curveParameterA, curveParameterB, maxUtilization));
    uint256 refRate = abi.decode(vm.ffi(ffi), (uint256));

    assertApproxEqRel(rate(u0, u1), refRate, 1.5e9);
  }

  function encodeHex(bytes memory raw) internal pure returns (string memory) {
    bytes16 symbols = "0123456789abcdef";
    bytes memory buffer = new bytes(2 * raw.length + 2);
    buffer[0] = "0";
    buffer[1] = "x";
    for (uint256 i = 0; i < raw.length; i++) {
      buffer[2 * i + 2] = symbols[uint8(raw[i]) >> 4];
      buffer[2 * i + 3] = symbols[uint8(raw[i]) & 0xf];
    }
    return string(buffer);
  }
}
