pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Dai is ERC20 {
    constructor() public ERC20('Dai Stablecoin', 'DAI') {}
}
