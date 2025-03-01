// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract Token is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) 
        ERC20(name, symbol, decimals) {}
    
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract TokenFixture is Test {
    Token public token0;
    Token public token1;

    function setUp() public virtual {
        token0 = new Token("Token0", "TK0", 18);
        token1 = new Token("Token1", "TK1", 18);
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
    }
}
