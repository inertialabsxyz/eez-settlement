// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TokenRegistry} from "../src/TokenRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, initialSupply);
    }
}

contract TokenRegistryTest is Test {
    TokenRegistry registry;
    MockToken tokenA;
    MockToken tokenB;

    function setUp() public {
        registry = new TokenRegistry();
        tokenA = new MockToken(1_000_000 ether);
        tokenB = new MockToken(1_000_000 ether);
    }

    function testRegister() public {
        assertEq(registry.register(address(tokenA)), 1);
        assertEq(registry.register(address(tokenA)), 1);
        assertEq(registry.register(address(tokenB)), 2);
        assertEq(registry.register(address(tokenB)), 2);
    }

    function testTokenAt() public {
        uint24 id = registry.register(address(tokenA));
        assertEq(address(tokenA), registry.tokenAt(id));
    }
}
