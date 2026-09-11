#!/usr/bin/env bash
#
# L2 half of the devnet deployment: `TokenRegistry`, `Book`, and the two
# cross-chain proxies that let the halves address each other.
#
# Run after script/install-l1.sh, which leaves the L1 addresses in
# script/deployments.env.
#
#     bash script/install-l2.sh
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source script/dev.env; set +a
source script/lib.sh
set -a; source "$DEPLOYMENTS"; set +a

require_env USDC WETH EXECUTOR RELAYER

L2="--rpc-url $L2_RPC --private-key $DEPLOYER_KEY"
L1="--rpc-url $L1_RPC --private-key $DEPLOYER_KEY"

step "Desynchronising the deployer's L2 nonce"
# Cosmetic, and worth the one transaction. The deployer starts both chains at the
# same nonce, so the Nth L1 contract and the Nth L2 contract land on the SAME
# address -- in one run `USDC` on L1 and `TokenRegistry` on L2 were both
# 0x663F…6602. Nothing breaks, because they are different chains, but a
# debugging session that reaches for the wrong `--rpc-url` then gets a live
# contract and a plausible answer instead of `0x`. Burning a nonce here keeps the
# two address spaces visibly apart.
cast send $L2 "$DEPLOYER" --value 0 >/dev/null

step "TokenRegistry (L2 only)"
# The registry holds L1 token addresses and never resolves one on L1 -- the
# cross-chain payload carries full addresses, so there is no mirror to keep in
# sync (§5.1.1).
REGISTRY=$(forge create src/TokenRegistry.sol:TokenRegistry $L2 --broadcast --json | jq -r .deployedTo)
record REGISTRY "$REGISTRY"
cast send $L2 "$REGISTRY" 'register(address)' "$USDC" >/dev/null
cast send $L2 "$REGISTRY" 'register(address)' "$WETH" >/dev/null
info "usdc id $(cast call "$REGISTRY" 'idOf(address)(uint24,bool)' "$USDC" --rpc-url "$L2_RPC" | tr '\n' ' ')"
info "weth id $(cast call "$REGISTRY" 'idOf(address)(uint24,bool)' "$WETH" --rpc-url "$L2_RPC" | tr '\n' ' ')"

step "Book"
# Book takes the L1 `Executor` and derives two things from it: the cross-chain
# proxy it dispatches to, and the EIP-712 domain the signature is scoped to.
# Those are different addresses, and the derivation lives in the constructor so
# a deployment cannot supply one where the other belongs (§5.3, Appendix D).
BOOK=$(forge create src/Book.sol:Book $L2 --broadcast --json --constructor-args \
    "$EEZL2_ADDRESS" "$EXECUTOR" "$EEZ_L1_ROLLUP_ID" "$REGISTRY" "$L1_CHAIN_ID" | jq -r .deployedTo)
record BOOK "$BOOK"

EXECUTOR_PROXY=$(cast call "$EEZL2_ADDRESS" 'computeCrossChainProxyAddress(address,uint64)(address)' \
    "$EXECUTOR" "$EEZ_L1_ROLLUP_ID" --rpc-url "$L2_RPC")
record EXECUTOR_PROXY "$EXECUTOR_PROXY"

expect_eq "book.l1Executor()" \
    "$(cast call "$BOOK" 'l1Executor()(address)' --rpc-url "$L2_RPC")" "$EXECUTOR"
expect_eq "book.executor() is the derived proxy" \
    "$(cast call "$BOOK" 'executor()(address)' --rpc-url "$L2_RPC")" "$EXECUTOR_PROXY"
expect_ne "the proxy is a different address from the Executor" "$EXECUTOR_PROXY" "$EXECUTOR"

step "The two chains agree on what a user signs (§5.3)"
# The check this whole deployment exists to make. `Book` verifies a signature at
# submission to fail fast; `Executor` verifies it again on L1 because that is the
# check that survives a compromised L2 (I9). If these two separators differ, L2
# accepts every intent and L1 rejects every settlement with `BadSignature(0)` --
# after the batch has already crossed.
#
# Nothing in the Foundry suite could establish this before the constructor
# change: `IdEEZ` derives the proxy as the identity, so the wrong address and the
# right one were the same address.
BOOK_DOMAIN=$(cast call "$BOOK" 'domainSeparator()(bytes32)' --rpc-url "$L2_RPC")
EXEC_DOMAIN=$(cast call "$EXECUTOR" 'domainSeparator()(bytes32)' --rpc-url "$L1_RPC")
expect_eq "domainSeparator, L2 Book vs L1 Executor" "$BOOK_DOMAIN" "$EXEC_DOMAIN"
record DOMAIN_SEPARATOR "$BOOK_DOMAIN"

step "Numeraire allowlist"
# I6: tokens[0] must be allowlisted and priced at PRICE_SCALE; I7 requires it on
# one leg of every trade. The only governance surface with teeth (§12).
cast send $L2 "$BOOK" 'setNumeraire(address,bool)' "$USDC" true >/dev/null
expect_eq "isNumeraire(USDC)" "$(cast call "$BOOK" 'isNumeraire(address)(bool)' "$USDC" --rpc-url "$L2_RPC")" "true"
expect_eq "isNumeraire(WETH) stays false" "$(cast call "$BOOK" 'isNumeraire(address)(bool)' "$WETH" --rpc-url "$L2_RPC")" "false"

step "Cross-chain proxies"
# Two of them, one per direction. The L2 side materialises the account `Book`
# dispatches through; the L1 side materialises the sender `Executor` will see.
# Creating only the first leaves the L1 leg with no sender.
info "L2: proxy for the L1 Executor"
cast send $L2 "$EEZL2_ADDRESS" 'createCrossChainProxy(address,uint64)' \
    "$EXECUTOR" "$EEZ_L1_ROLLUP_ID" >/dev/null
info "L1: proxy for the L2 Book"
cast send $L1 "$EEZ_REGISTRY_ADDRESS" 'createCrossChainProxy(address,uint64)' \
    "$BOOK" "$EEZ_ROLLUP_ID" >/dev/null || note "already created"

step "setL2Caller -- last, and one-shot"
cast send $L1 "$EXECUTOR" 'setL2Caller(address)' "$BOOK" >/dev/null
BOOK_PROXY=$(cast call "$EEZ_REGISTRY_ADDRESS" 'computeCrossChainProxyAddress(address,uint64)(address)' \
    "$BOOK" "$EEZ_ROLLUP_ID" --rpc-url "$L1_RPC")
record BOOK_PROXY "$BOOK_PROXY"
expect_eq "executor.expectedProxy()" \
    "$(cast call "$EXECUTOR" 'expectedProxy()(address)' --rpc-url "$L1_RPC")" "$BOOK_PROXY"

step "L2 done"
info "wrote $DEPLOYMENTS"
[ "$FAILURES" -eq 0 ] || die "$FAILURES check(s) failed"
