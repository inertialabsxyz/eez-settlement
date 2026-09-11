// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// A fixed-price market maker with finite inventory. Demo scaffolding, not
/// protocol code: it is deployed only by `script/install-l1.sh` and nothing in
/// `src/` knows it exists.
///
/// It is here because every other venue in the demo is a constant-product AMM,
/// and a router that only ever compares AMMs is comparing the same curve at
/// different depths. This one quotes a flat price until its inventory runs out
/// and then quotes nothing, so the best route genuinely depends on trade size:
/// small orders should prefer it (no slippage), large ones must fall back to the
/// pools or split. That is the behaviour a path-finder has to actually reason
/// about rather than just rank.
///
/// From `Executor`'s side it is an ordinary interaction target — approve, then
/// swap — indistinguishable from the Uniswap router, which is the point: I12
/// forbids an interaction targeting `Relayer` and says nothing about what else a
/// solver may call.
contract OtcMaker {
    using SafeERC20 for IERC20;

    address public immutable admin;

    /// out-per-in, scaled by 1e18. Zero means the pair is not quoted.
    mapping(address => mapping(address => uint256)) public price;

    error NotAdmin();
    error NotQuoted();
    error InsufficientInventory(uint256 want, uint256 have);
    error BelowMinOut(uint256 got, uint256 minOut);

    event Quoted(address indexed tokenIn, address indexed tokenOut, uint256 price);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    constructor() {
        admin = msg.sender;
    }

    function setPrice(address tokenIn, address tokenOut, uint256 outPerIn) external {
        if (msg.sender != admin) revert NotAdmin();
        price[tokenIn][tokenOut] = outPerIn;
        emit Quoted(tokenIn, tokenOut, outPerIn);
    }

    /// What this maker would pay for `amountIn`, or zero if it cannot fill.
    ///
    /// Returning zero rather than reverting is deliberate: a router quotes every
    /// venue for every candidate leg, and a venue that reverts on an
    /// unfillable size forces the caller to wrap each quote in a try/catch.
    function quote(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        uint256 p = price[tokenIn][tokenOut];
        if (p == 0) return 0;
        uint256 out = (amountIn * p) / 1e18;
        if (out > IERC20(tokenOut).balanceOf(address(this))) return 0;
        return out;
    }

    function inventory(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// Pulls `amountIn` from the caller, so the caller must have approved this
    /// contract first — the same two-step an AMM router needs, so a solver's
    /// interaction list has the same shape whichever venue it picks.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 out)
    {
        uint256 p = price[tokenIn][tokenOut];
        if (p == 0) revert NotQuoted();

        out = (amountIn * p) / 1e18;
        uint256 have = IERC20(tokenOut).balanceOf(address(this));
        if (out > have) revert InsufficientInventory(out, have);
        if (out < minOut) revert BelowMinOut(out, minOut);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(to, out);

        emit Swapped(tokenIn, tokenOut, amountIn, out);
    }
}
