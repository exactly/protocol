// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/presets/ERC721PresetMinterPauserAutoId.sol";

contract EToken is ERC721PresetMinterPauserAutoId {

    constructor() ERC721PresetMinterPauserAutoId(
            "EToken",
            "ET",
            "https://exactly.com/api/token/"
        ) {}
}