// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// ---------------------------------------------------------------------------
// The cross-chain payload
// ---------------------------------------------------------------------------

/// One user's participation in a settlement.
///
/// `sellAmount` is fixed; the buy amount is derived from the clearing price
/// vector, which is what makes uniform pricing structural rather than checked.
///
/// `deadline` and `nonce` are carried because L1 must rebuild the EIP-712 digest
/// and has no other way to obtain them — it cannot read L2 storage, which is the
/// premise of the whole arrangement.
struct Trade {
    address account;
    uint8 sellIdx; // index into SettlementData.tokens
    uint8 buyIdx;
    uint128 sellAmount;
    uint128 limit; // minimum acceptable buy amount
    uint40 deadline;
    uint64 nonce;
}

/// An arbitrary L1 call used to source the residual from a venue.
///
/// No `value` field: `Executor` has no `receive()` and cannot hold ETH, so it
/// would always be zero. Its absence also removes the only path by which an
/// interaction could move native value.
struct Interaction {
    address target;
    bytes callData;
}

/// The whole payload that crosses the chain boundary, in one dispatch.
struct SettlementData {
    address[] tokens;
    uint256[] clearingPrices; // numeraire units per token, indexed like `tokens`
    Trade[] trades;
    Interaction[] calls;
}

// ---------------------------------------------------------------------------
// The signed authorisation
// ---------------------------------------------------------------------------

/// What the user actually signs.
///
/// Distinct from `Book`'s stored `Intent`, which holds `uint24` registry ids:
/// this is the canonical form the signature covers, and it must be
/// reconstructible on L1, which has no registry. Addresses, therefore, not ids.
///
/// Every numeric field is `uint256` even though the payload carries them narrow.
/// EIP-712 `encodeData` pads to 32 bytes regardless, so this costs nothing
/// on-chain, and non-standard widths like `uint40` are unevenly supported by
/// wallet signing libraries. The type string is what wallets hash and render;
/// it should use only types every implementation agrees on.
struct SignedIntent {
    address account;
    address sellToken;
    address buyToken;
    uint256 sellAmount;
    uint256 limit;
    uint256 deadline;
    uint256 nonce;
}

/// One definition of the domain and struct hash, shared by both chains.
///
/// `Book` verifies a signature at submission to fail fast; `Executor` verifies it
/// again at pull time because that is the check that survives a compromised L2.
/// Those two must agree exactly, so neither computes its own — a divergence here
/// would be silent on L2 and fatal on L1.
library SettlementEIP712 {
    string internal constant NAME = "EEZ Settlement";
    string internal constant VERSION = "1";

    bytes32 internal constant INTENT_TYPEHASH = keccak256(
        "Intent(address account,address sellToken,address buyToken,"
        "uint256 sellAmount,uint256 limit,uint256 deadline,uint256 nonce)"
    );

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// The domain is pinned to the **L1** chain and the `Executor` address,
    /// because that is where the signature is consumed. `Book` reproduces it
    /// with the L1 chain id it was deployed against — it must not use its own.
    function domainSeparator(uint256 l1ChainId, address executor) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(NAME)), keccak256(bytes(VERSION)), l1ChainId, executor)
            );
    }

    function hashStruct(SignedIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                INTENT_TYPEHASH,
                intent.account,
                intent.sellToken,
                intent.buyToken,
                intent.sellAmount,
                intent.limit,
                intent.deadline,
                intent.nonce
            )
        );
    }

    function digest(bytes32 separator, SignedIntent memory intent) internal pure returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(separator, hashStruct(intent));
    }
}
