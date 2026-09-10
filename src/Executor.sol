// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SettlementData, Trade, Interaction, SignedIntent, SettlementEIP712} from "./SettlementTypes.sol";
import {Relayer} from "./Relayer.sol";

interface IEEZ {
    function computeCrossChainProxyAddress(
        address target,
        uint64 rollupId
    ) external view returns (address);
}

/// The L1 half. Verifies, performs a payload, and refuses to end the
/// transaction holding a different balance than it started with.
///
/// It understands nothing about intents, auctions or pricing — that is all L2.
/// What it does not delegate is authorisation: every pull carries the account's
/// own EIP-712 signature, so neither the L2 book nor the bridge can move funds
/// a user did not sign for.
contract Executor {
    using SafeERC20 for IERC20;

    Relayer public immutable relayer;
    address public immutable windfallRecipient;
    address public immutable eez;
    uint64 public immutable l2RollupId;
    address public immutable admin;

    /// Cached at setL2Caller: the derivation is a cold external call, and the
    /// result never changes.
    address public expectedProxy;

    /// account => nonce word => bitmap. Unordered, because a sequential nonce
    /// would force a user's intents to settle in submission order — which cannot
    /// hold when they land in different batches.
    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    uint256 private immutable _cachedChainId;
    bytes32 private immutable _cachedSeparator;

    error NotProxy();
    error NotAdmin();
    error ProxyAlreadySet();
    error LengthMismatch();
    error BadSignature(uint256 index);
    error IntentExpired(uint256 index);
    error NonceUsed(uint256 index);
    error TargetForbidden(uint256 index);
    error InteractionFailed(uint256 index);
    error LimitNotMet(uint256 index, uint256 got, uint256 want);
    error NotSolvent(address token);
    error BalanceNotRestored(address token);
    error EthLeaked();

    event Settled(uint256 trades, uint256 interactions);

    constructor(address _eez, uint64 _l2RollupId, address _windfallRecipient) {
        require(
            _windfallRecipient != address(0),
            "windfall recipient required"
        );
        admin = msg.sender;
        eez = _eez;
        l2RollupId = _l2RollupId;
        windfallRecipient = _windfallRecipient;
        relayer = new Relayer(address(this));

        _cachedChainId = block.chainid;
        _cachedSeparator = SettlementEIP712.domainSeparator(
            block.chainid,
            address(this)
        );
    }

    function setL2Caller(address book) external {
        if (msg.sender != admin) revert NotAdmin();
        if (expectedProxy != address(0)) revert ProxyAlreadySet();
        address p = IEEZ(eez).computeCrossChainProxyAddress(book, l2RollupId);
        require(p != address(0), "bad proxy");
        expectedProxy = p;
    }

    /// Re-derive across a chain split rather than caching blindly, or signatures
    /// from the original chain replay on the fork.
    ///
    /// `Book` reproduces this same value from the L1 chain id it was deployed
    /// against. Both sides compute it through `SettlementEIP712` and neither
    /// writes its own — a divergence here would pass on L2 at submission and
    /// fail on L1 after the batch had already crossed.
    function domainSeparator() public view returns (bytes32) {
        return
            block.chainid == _cachedChainId
                ? _cachedSeparator
                : SettlementEIP712.domainSeparator(
                    block.chainid,
                    address(this)
                );
    }

    // ------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------

    /// @notice Perform a settlement. Callable only by the L2 book's cross-chain proxy.
    ///
    /// Ordering is verify -> pull -> interact -> pay -> restore. Pull before
    /// interact funds the route from the batch itself, so a solver needs no
    /// capital. Interact before pay lets the route produce the buy side. Any
    /// failure, on either chain, unwinds all of it.
    ///
    /// I19: this is the only entry point that emits calls or moves value. The
    /// reentrancy argument depends on it — a target re-entering here fails the
    /// proxy check, and there is nowhere else to enter.
    function settle(
        SettlementData calldata d,
        bytes[] calldata signatures
    ) external {
        if (msg.sender != expectedProxy) revert NotProxy();
        if (signatures.length != d.trades.length) revert LengthMismatch();
        if (d.clearingPrices.length != d.tokens.length) revert LengthMismatch();

        uint256 nTokens = d.tokens.length;
        uint256[] memory opening = new uint256[](nTokens);
        for (uint256 i = 0; i < nTokens; i++) {
            opening[i] = IERC20(d.tokens[i]).balanceOf(address(this));
        }
        uint256 openingEth = address(this).balance;

        _verifyAndPull(d, signatures);
        _interact(d);
        _pay(d);
        _restore(d, opening, openingEth);

        emit Settled(d.trades.length, d.calls.length);
    }

    /// Recover each account's signature over the exact terms being executed, then
    /// pull in one call. I9 and I10 — the checks that survive a compromised L2.
    function _verifyAndPull(
        SettlementData calldata d,
        bytes[] calldata signatures
    ) private {
        uint256 n = d.trades.length;
        address[] memory tokens = new address[](n);
        address[] memory froms = new address[](n);
        uint128[] memory amounts = new uint128[](n);

        bytes32 separator = domainSeparator();

        for (uint256 i = 0; i < n; i++) {
            Trade calldata t = d.trades[i];
            address sellToken = d.tokens[t.sellIdx];

            if (block.timestamp > t.deadline) revert IntentExpired(i);
            _consumeNonce(t.account, t.nonce, i);

            // The narrow payload widths widen implicitly into the signed form.
            // Only `SignedIntent` is canonical; `Trade` is an encoding of it
            // chosen for calldata size.
            bytes32 digest = SettlementEIP712.digest(
                separator,
                SignedIntent({
                    account: t.account,
                    sellToken: sellToken,
                    buyToken: d.tokens[t.buyIdx],
                    sellAmount: t.sellAmount,
                    limit: t.limit,
                    deadline: t.deadline,
                    nonce: t.nonce
                })
            );
            // OZ's recover reverts on a malleable or malformed signature rather
            // than returning address(0), so high-s is rejected for us.
            if (ECDSA.recover(digest, signatures[i]) != t.account)
                revert BadSignature(i);

            tokens[i] = sellToken;
            froms[i] = t.account;
            amounts[i] = t.sellAmount;
        }

        relayer.pullBatch(tokens, froms, amounts);
    }

    function _consumeNonce(address account, uint64 nonce, uint256 i) private {
        uint256 word = nonce >> 8;
        uint256 bit = 1 << (nonce & 0xff);
        uint256 bits = nonceBitmap[account][word];
        if (bits & bit != 0) revert NonceUsed(i);
        nonceBitmap[account][word] = bits | bit;
    }

    /// Solver-supplied arbitrary calls. Two rules, both load-bearing:
    /// I12 — the relayer is unreachable, because it holds every approval and
    /// answers to this contract; and I18 — this is `call`, never `delegatecall`,
    /// which would let a target execute as this contract and void both.
    function _interact(SettlementData calldata d) private {
        address r = address(relayer);
        for (uint256 i = 0; i < d.calls.length; i++) {
            Interaction calldata c = d.calls[i];
            if (c.target == r) revert TargetForbidden(i);
            (bool ok, ) = c.target.call(c.callData);
            if (!ok) revert InteractionFailed(i);
        }
    }

    /// Uniform pricing is structural: every output derives from the same vector,
    /// so a settlement favouring one account is not expressible.
    ///
    /// I16: this loop is unconditional. No branch may skip a trade — a skipped
    /// payment leaves the user's tokens in this contract, where `_restore` would
    /// sweep them away as residue.
    function _pay(SettlementData calldata d) private {
        for (uint256 i = 0; i < d.trades.length; i++) {
            Trade calldata t = d.trades[i];
            uint256 buyAmount = Math.mulDiv(
                t.sellAmount,
                d.clearingPrices[t.sellIdx],
                d.clearingPrices[t.buyIdx]
            );
            if (buyAmount < t.limit) revert LimitNotMet(i, buyAmount, t.limit);
            IERC20(d.tokens[t.buyIdx]).safeTransfer(t.account, buyAmount);
        }
    }

    /// I11 — the one check that cannot be delegated to L2. Every listed token
    /// must end at exactly its opening balance; in steady state, zero.
    ///
    /// I17 — residue goes to a protocol address the solver cannot name. A
    /// solver-nominated destination would turn any failure to pay a user into
    /// solver revenue, with every balance check still passing.
    function _restore(
        SettlementData calldata d,
        uint256[] memory opening,
        uint256 openingEth
    ) private {
        for (uint256 i = 0; i < d.tokens.length; i++) {
            IERC20 token = IERC20(d.tokens[i]);
            uint256 bal = token.balanceOf(address(this));
            if (bal < opening[i]) revert NotSolvent(d.tokens[i]);
            if (bal > opening[i]) {
                token.safeTransfer(windfallRecipient, bal - opening[i]);
                // Re-read rather than assume: a fee-on-transfer token would leave
                // residue behind, and this is what makes I11 an equality rather
                // than a bound.
                if (token.balanceOf(address(this)) != opening[i]) {
                    revert BalanceNotRestored(d.tokens[i]);
                }
            }
        }
        // No `receive()`, so this can only move if an interaction forced value in.
        if (address(this).balance != openingEth) revert EthLeaked();
    }
}
