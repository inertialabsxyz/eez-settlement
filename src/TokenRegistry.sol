// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenRegistry {
    mapping(address => uint24) _ids;
    address[] tokens;

    error UnknownToken();
    error NotToken();

    function register(address token) external returns (uint24) {
        if (_ids[token] > 0) return _ids[token];
        if (!_isERC20(token)) revert NotToken();
        tokens.push(token);
        uint24 id = uint24(tokens.length);
        _ids[token] = id;
        return id;
    }

    function tokenAt(uint24 id) external view returns (address) {
        if (id == 0 || tokens.length < id) revert UnknownToken();
        return tokens[uint256(id) - 1];
    }

    function idOf(address token) external view returns (uint24 id, bool found) {
        id = _ids[token];
        found = id > 0;
    }

    function _isERC20(address token) private view returns (bool) {
        if (token.code.length == 0) return false;

        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC20.totalSupply, ()));
        if (!ok || data.length != 32) return false;

        (ok, data) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && data.length == 32;
    }
}
