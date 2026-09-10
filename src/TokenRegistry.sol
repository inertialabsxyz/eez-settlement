// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Append-only, permissionless, ungoverned map of id to ERC-20 address.
///
/// It exists for one reason: to compress `Book`'s `Intent` into two storage
/// slots. An id is an index, not an endorsement — every invariant in the
/// specification holds regardless of what is registered here. The numeraire
/// allowlist is the governed surface, and it lives on `Book`.
///
/// L2-only. The cross-chain payload carries full addresses, so L1 never resolves
/// an id and there is no mirror to keep in sync.
contract TokenRegistry {
    /// id == index.
    address[] public tokens;

    /// Stores `id + 1`, so a zero read means unregistered. The first token
    /// registered legitimately holds id 0, which a bare sentinel could not
    /// distinguish from absence.
    mapping(address => uint256) private _id;

    /// `uint24` rather than `uint16`: registration is permissionless, and a
    /// 65,536-entry ceiling is reachable by spam for roughly 2.6 billion gas,
    /// after which no further token could ever be listed. The wider id fills
    /// `Intent` slot 0 exactly, so it costs nothing.
    uint256 private constant MAX_ID = type(uint24).max;

    error ZeroAddress();
    error RegistryFull();
    error UnknownId();

    event Registered(address indexed token, uint24 id);

    /// Idempotent: a token cannot acquire two ids. Not a safety issue — `Book`
    /// resolves id to address before matching — but wasteful and confusing.
    function register(address token) external returns (uint24 id) {
        if (token == address(0)) revert ZeroAddress();

        uint256 existing = _id[token];
        if (existing != 0) return uint24(existing - 1);

        uint256 next = tokens.length;
        if (next > MAX_ID) revert RegistryFull();

        tokens.push(token);
        _id[token] = next + 1;
        id = uint24(next);

        emit Registered(token, id);
    }

    function tokenAt(uint24 id) external view returns (address) {
        if (id >= tokens.length) revert UnknownId();
        return tokens[id];
    }

    /// Returns `found` separately for the id-0 reason above.
    function idOf(address token) external view returns (uint24 id, bool found) {
        uint256 stored = _id[token];
        if (stored == 0) return (0, false);
        return (uint24(stored - 1), true);
    }

    function count() external view returns (uint256) {
        return tokens.length;
    }
}
