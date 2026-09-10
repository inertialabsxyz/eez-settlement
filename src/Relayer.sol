// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Holds user approvals, and nothing else.
///
/// The separation from `Executor` is structural, not defence in depth. `Executor`
/// runs solver-supplied arbitrary calls; if it also held approvals, an
/// interaction could call `token.transferFrom(victim, attacker, ...)` and drain
/// every user who had ever approved it — and the balance invariant would not
/// notice, because those tokens never pass through `Executor` at all.
contract Relayer {
    using SafeERC20 for IERC20;

    address public immutable executor;

    error NotExecutor();
    error LengthMismatch();

    constructor(address _executor) {
        executor = _executor;
    }

    /// No `to` parameter: funds always land in `Executor`. A caller-specified
    /// destination would be safe only for as long as every caller passed the
    /// right thing.
    function pullBatch(
        address[] calldata tokens,
        address[] calldata froms,
        uint128[] calldata amounts
    ) external {
        if (msg.sender != executor) revert NotExecutor();
        if (tokens.length != froms.length || tokens.length != amounts.length) {
            revert LengthMismatch();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).safeTransferFrom(froms[i], executor, amounts[i]);
        }
    }
}
