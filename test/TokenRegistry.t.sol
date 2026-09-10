// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

    /// §5.1.1: `id == index`, so the first token registered holds id 0 — not 1.
    /// Registration is idempotent, so a token cannot acquire two ids.
    function testRegister() public {
        assertEq(registry.register(address(tokenA)), 0);
        assertEq(registry.register(address(tokenA)), 0);
        assertEq(registry.register(address(tokenB)), 1);
        assertEq(registry.register(address(tokenB)), 1);
    }

    function testTokenAt() public {
        uint24 id = registry.register(address(tokenA));
        assertEq(address(tokenA), registry.tokenAt(id));
    }
}
