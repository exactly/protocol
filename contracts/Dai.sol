//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Dai is ERC20 {
    constructor() ERC20('Dai Stablecoin', 'DAI') {}

    function faucet(address recipient, uint amount) external {
        _mint(recipient, amount);
    }
}
