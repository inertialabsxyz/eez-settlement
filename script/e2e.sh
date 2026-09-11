#!/usr/bin/env bash
#
# End-to-end settlement against the live `eez-dev` enclave.
#
#     bash script/install-l1.sh
#     bash script/install-l2.sh
#     bash script/e2e.sh [cow|route|all]
#
# Two settlements, both driven the way a real solver would drive them: intents
# signed off-chain as EIP-712 typed data, a sealed commitment, a reveal after the
# commit deadline, and one cross-chain dispatch that either lands on both chains
# or on neither.
#
#   cow    two intents that clear against each other. No interactions, no solver
#          capital, and -- because the batch nets exactly -- no residue, which
#          makes I11's equality observable rather than merely satisfied.
#   route  one intent with no counterparty, filled by swapping the pulled tokens
#          through a real Uniswap V2 pool inside the settlement. This is the
#          "liquidity sourced on L1 inside a single dispatch" claim, and it is
#          the case that exercises `_interact` and the residue sweep (I17).
#
# Everything here asserts on the EFFECT, never on the exit code of a send. §13.4
# records that the previous harness did the opposite and passed vacuously; on
# this stack a cross-chain transaction can be accepted, return a hash, change L2
# state and then silently unwind on both chains.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source script/dev.env; set +a
source script/lib.sh
set -a; source "$DEPLOYMENTS"; set +a

require_env USDC WETH EXECUTOR RELAYER REGISTRY BOOK EXECUTOR_PROXY WINDFALL

WHICH="${1:-all}"

PRICE_SCALE=1000000000000000000
COMMIT_WINDOW=$(cast call "$BOOK" 'COMMIT_WINDOW()(uint40)' --rpc-url "$L2_RPC" | awk '{print $1}')
REVEAL_WINDOW=$(cast call "$BOOK" 'REVEAL_WINDOW()(uint40)' --rpc-url "$L2_RPC" | awk '{print $1}')

# ---------------------------------------------------------------------------
# Reads
# ---------------------------------------------------------------------------

# leadCommitment, leader, leadScore, settled, commitDeadline, revealDeadline, leadIdx
auction() {
    cast call "$BOOK" 'auctions(uint256)(bytes32,address,uint88,bool,uint40,uint40,uint16)' "$1" \
        --rpc-url "$L2_RPC" | sed -n "$2p" | awk '{print $1}'
}
auction_settled()        { auction "$1" 4; }
auction_commit_deadline(){ auction "$1" 5; }
auction_reveal_deadline(){ auction "$1" 6; }

intent_state() {
    # account, sellTok, buyTok, deadline, state, sellAmount, limit
    cast call "$BOOK" 'intents(uint256)(address,uint24,uint24,uint40,uint8,uint128,uint128)' "$1" \
        --rpc-url "$L2_RPC" | sed -n 5p | awk '{print $1}'
}

# I10 is enforced on L1 and only on L1 -- Book's bitmap is a courtesy mirror, so
# reading L2 here would prove nothing about the check that survives a
# compromised L2. Word `nonce / 256`, bit `nonce % 256`, per account.
nonce_used_on_l1() {
    local who="$1" nonce="$2" bits
    bits=$(cast call "$EXECUTOR" 'nonceBitmap(address,uint256)(uint256)' "$who" "$((nonce / 256))" \
        --rpc-url "$L1_RPC" | awk '{print $1}')
    # A 256-bit word; shell arithmetic is 64-bit and would silently truncate it.
    python3 -c "print('true' if (int('$bits') >> ($nonce % 256)) & 1 else 'false')"
}

# Block until L1 records the nonce a settlement's pull consumed. This is the
# effect, not a proxy for it: `Executor._consumeNonce` runs inside `settle`, so
# the bit is set if and only if the L1 leg executed and stuck.
wait_l1_nonce() {
    local who="$1" nonce="$2" timeout="${3:-180}" i
    for i in $(seq 1 "$timeout"); do
        [ "$(nonce_used_on_l1 "$who" "$nonce")" = "true" ] && return 0
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# Intents
# ---------------------------------------------------------------------------

# Sign an intent as EIP-712 typed data, exactly as a wallet would.
#
# The domain here is built from fields rather than from `book.domainSeparator()`,
# because that is the only thing a wallet can do -- it hashes `name`, `version`,
# `chainId` and `verifyingContract` itself. Both fields are read back off the
# chains rather than taken from the deployment file, and `submitIntent` then
# verifies the result against `book.domainSeparator()` on L2 and `Executor`
# re-verifies it on L1 (I9). A domain assembled wrongly here does not pass
# quietly; it fails at the first of those two checks.
sign_intent() {
    local key="$1" account="$2" sell="$3" buy="$4" amount="$5" limit="$6" deadline="$7" nonce="$8"
    local l1_chain verifying json
    l1_chain=$(cast chain-id --rpc-url "$L1_RPC")
    verifying=$(cast call "$BOOK" 'l1Executor()(address)' --rpc-url "$L2_RPC")

    json=$(jq -nc \
        --argjson chainId "$l1_chain" --arg verifying "$verifying" \
        --arg account "$account" --arg sell "$sell" --arg buy "$buy" \
        --arg amount "$amount" --arg limit "$limit" --arg deadline "$deadline" --arg nonce "$nonce" '
    {
      types: {
        EIP712Domain: [
          {name:"name",type:"string"},{name:"version",type:"string"},
          {name:"chainId",type:"uint256"},{name:"verifyingContract",type:"address"}
        ],
        Intent: [
          {name:"account",type:"address"},{name:"sellToken",type:"address"},
          {name:"buyToken",type:"address"},{name:"sellAmount",type:"uint256"},
          {name:"limit",type:"uint256"},{name:"deadline",type:"uint256"},
          {name:"nonce",type:"uint256"}
        ]
      },
      primaryType: "Intent",
      domain: {name:"EEZ Settlement", version:"1", chainId:$chainId, verifyingContract:$verifying},
      message: {
        account:$account, sellToken:$sell, buyToken:$buy,
        sellAmount:$amount, limit:$limit, deadline:$deadline, nonce:$nonce
      }
    }')
    cast wallet sign --private-key "$key" --data "$json"
}

# Submit a signed intent from the trader's own account and echo its id.
# `submitIntent` requires `intent.account == msg.sender`, so this cannot be
# batched through the deployer.
submit_intent() {
    local key="$1" account="$2" sell="$3" buy="$4" amount="$5" limit="$6" deadline="$7" nonce="$8" sig="$9"
    local id
    id=$(cast call "$BOOK" 'intentCount()(uint256)' --rpc-url "$L2_RPC" | awk '{print $1}')
    cast send --rpc-url "$L2_RPC" --private-key "$key" "$BOOK" \
        'submitIntent((address,address,address,uint256,uint256,uint256,uint256),bytes)' \
        "($account,$sell,$buy,$amount,$limit,$deadline,$nonce)" "$sig" >/dev/null
    echo "$id"
}

# ---------------------------------------------------------------------------
# The auction
# ---------------------------------------------------------------------------

# Build the payload offline and echo "commitment score revealCalldata".
# All the ABI encoding happens in Solidity; see script/DevnetPayload.s.sol.
plan() {
    local out
    out=$(BOOK="$BOOK" SOLVER="$SOLVER" AUCTION_ID="$1" SALT="$SALT" L2_CHAIN_ID="$L2_CHAIN_ID" \
        forge script script/DevnetPayload.s.sol:DevnetPayload --sig 'plan()' --json 2>/dev/null \
        | jq -sr '[.[] | select(.returns)] | last | .returns
              | "\(.commitment.value) \(.score.value) \(.revealCalldata.value)"')
    [ -n "$out" ] && [ "$out" != "null null null" ] || { echo "forge script plan() produced nothing" >&2; return 1; }
    echo "$out"
}

# Commit, wait out the commit phase, reveal across the chain boundary, and then
# prove the settlement landed on both chains or on neither.
#
# Returns 0 when the settlement is observably complete on both sides.
run_auction() {
    local label="$1" claimed_score="$2"
    local id commitment score calldata t_c t_r sent_nonce hash i settled

    id=$(cast call "$BOOK" 'liveAuction()(uint256)' --rpc-url "$L2_RPC" | awk '{print $1}')
    read -r commitment score calldata <<<"$(plan "$id")"
    info "auction $id  commitment ${commitment:0:18}  score $score  payload $(( (${#calldata} - 2) / 2 )) B"

    [ "$claimed_score" = "exact" ] && claimed_score="$score"

    # `commitBid` is pure L2 -- it emits no cross-chain call -- so it goes to the
    # ordinary RPC. Only the reveal touches L1.
    cast send --rpc-url "$L2_RPC" --private-key "$SOLVER_KEY" "$BOOK" \
        'commitBid(uint256,bytes32,uint88)' "$id" "$commitment" "$claimed_score" >/dev/null
    t_c=$(auction_commit_deadline "$id")
    t_r=$(auction_reveal_deadline "$id")
    info "committed; T_C $t_c, T_R $t_r, L2 now $(l2_now)"

    # I14: the reveal window opens at T_C and not before. A harness that
    # committed and revealed back to back would be testing nothing --
    # `revealAndExecute` reverts `CommitPhaseOpen` until the leader is frozen.
    info "waiting out the commit phase (${COMMIT_WINDOW}s)"
    wait_until_l2 "$t_c"

    sent_nonce=$(front_nonce "$SOLVER")
    hash=$(xsend "$SOLVER_KEY" "$SOLVER" "$BOOK" "$calldata" 8000000) \
        || { fail "$label: the front rejected the reveal"; return 1; }
    info "reveal dispatched: $hash"

    # The front does not advance its nonce until the call has settled on both
    # chains. The L2 effect appears earlier than that and can still unwind, so
    # the nonce is the signal and `auctions(id).settled` is the confirmation.
    if wait_settled "$SOLVER" "$sent_nonce" 150; then
        info "front nonce advanced"
    else
        note "front nonce did not advance within 150s; checking the effect anyway"
    fi

    for i in $(seq 1 30); do
        settled=$(auction_settled "$id")
        [ "$settled" = "true" ] && break
        sleep 2
    done

    if [ "$settled" != "true" ]; then
        note "auction $id is not settled (L2 now $(l2_now), T_R $t_r)"
        return 1
    fi
    pass "$label: auction $id settled on L2"

    # L2 settling is only half of it, and it is the half that can unwind. The
    # front's nonce advances on its own reservation schedule, not on the L1
    # leg's visibility -- the first run of this harness asserted immediately
    # after the nonce moved and read an L1 that had not caught up, reporting a
    # settlement that had in fact landed correctly one block later. So wait for
    # a fact only the L1 half can produce: the nonce the pull consumed there.
    if wait_l1_nonce "$WITNESS_ACCOUNT" "$WITNESS_NONCE" 180; then
        pass "$label: L1 consumed ${WITNESS_ACCOUNT:0:10}'s nonce $WITNESS_NONCE -- the pull happened (I9, I10)"
        LAST_AUCTION="$id"
        return 0
    fi

    # L2 says settled and L1 never moved. That is not slowness, it is the
    # atomicity claim failing: §9 says the whole settlement lands on L1 or none
    # of it does, and every L2 write unwinds with it.
    fail "$label: auction $id is settled on L2 but L1 never consumed the nonce -- the two chains disagree"
    return 1

    note "auction $id is not settled (L2 now $(l2_now), T_R $t_r)"
    return 1
}

# The first outbound call through a freshly created cross-chain proxy executes,
# appears on L2, and then rolls back on both chains -- no revert, no error. A
# retry is the documented remedy, and it retroactively settles the first
# attempt. The intents are untouched by a rolled-back reveal (their state is
# still LIVE and their L2 nonces were consumed by `submitIntent`, which is an
# ordinary L2 transaction), so a retry re-commits the same payload against a
# fresh auction.
settle_with_retry() {
    local label="$1" attempts="${2:-3}" i
    for i in $(seq 1 "$attempts"); do
        [ "$i" -gt 1 ] && note "attempt $i of $attempts (the first call through a new proxy rolls back silently)"
        if run_auction "$label" exact; then return 0; fi
    done
    fail "$label: no settlement after $attempts attempts"
    return 1
}

# ---------------------------------------------------------------------------
# Phase 1 -- coincidence of wants
# ---------------------------------------------------------------------------

phase_cow() {
    step "Phase 1: coincidence of wants (no interactions, no residue)"

    local dl a_usdc0 b_usdc0 a_weth0 b_weth0 x_usdc0 x_weth0 w_weth0 sig_a sig_b id_a id_b
    dl=$(( $(l2_now) + 86400 ))

    a_usdc0=$(balance_of "$USDC" "$ALICE" "$L1_RPC"); a_weth0=$(balance_of "$WETH" "$ALICE" "$L1_RPC")
    b_usdc0=$(balance_of "$USDC" "$BOB" "$L1_RPC");   b_weth0=$(balance_of "$WETH" "$BOB" "$L1_RPC")
    x_usdc0=$(balance_of "$USDC" "$EXECUTOR" "$L1_RPC"); x_weth0=$(balance_of "$WETH" "$EXECUTOR" "$L1_RPC")
    w_weth0=$(balance_of "$WETH" "$WINDFALL" "$L1_RPC")

    # Alice sells 2,000 USDC for at least 0.9 WETH; Bob sells 1 WETH for at least
    # 1,900 USDC. At 2,000 USDC/WETH they fill each other exactly.
    sig_a=$(sign_intent "$ALICE_KEY" "$ALICE" "$USDC" "$WETH" 2000000000000000000000 900000000000000000 "$dl" 0)
    sig_b=$(sign_intent "$BOB_KEY"   "$BOB"   "$WETH" "$USDC" 1000000000000000000    1900000000000000000000 "$dl" 0)
    id_a=$(submit_intent "$ALICE_KEY" "$ALICE" "$USDC" "$WETH" 2000000000000000000000 900000000000000000 "$dl" 0 "$sig_a")
    id_b=$(submit_intent "$BOB_KEY"   "$BOB"   "$WETH" "$USDC" 1000000000000000000    1900000000000000000000 "$dl" 0 "$sig_b")
    info "intents $id_a (alice) and $id_b (bob) accepted on L2"

    export TOKENS="$USDC,$WETH"
    export PRICES="$PRICE_SCALE,2000000000000000000000"
    export TRADE_ACCOUNTS="$ALICE,$BOB"
    export TRADE_SELL_IDX="0,1"
    export TRADE_BUY_IDX="1,0"
    export TRADE_SELL_AMOUNTS="2000000000000000000000,1000000000000000000"
    export TRADE_LIMITS="900000000000000000,1900000000000000000000"
    export TRADE_DEADLINES="$dl,$dl"
    export TRADE_NONCES="0,0"
    export INTENT_IDS="$id_a,$id_b"
    export SIGS="$sig_a,$sig_b"
    unset CALL_TARGETS CALL_DATAS
    SALT=0x0000000000000000000000000000000000000000000000000000000000000001
    WITNESS_ACCOUNT="$ALICE"; WITNESS_NONCE=0

    settle_with_retry "cow" 3 || return 1

    step "Phase 1 effects"
    expect_eq "intent $id_a is FILLED on L2" "$(intent_state "$id_a")" "2"
    expect_eq "intent $id_b is FILLED on L2" "$(intent_state "$id_b")" "2"

    # I9/I10: the pull happened on L1 under the user's own signature, and the
    # nonce it carried is now spent there.
    expect_eq "alice nonce 0 consumed on L1 (I10)" "$(nonce_used_on_l1 "$ALICE" 0)" "true"
    expect_eq "bob nonce 0 consumed on L1 (I10)"   "$(nonce_used_on_l1 "$BOB" 0)"   "true"

    expect_eq "alice USDC -2000" "$(balance_of "$USDC" "$ALICE" "$L1_RPC")" "$(bn_sub "$a_usdc0" 2000000000000000000000)"
    expect_eq "alice WETH +1"    "$(balance_of "$WETH" "$ALICE" "$L1_RPC")" "$(bn_add "$a_weth0" 1000000000000000000)"
    expect_eq "bob WETH -1"      "$(balance_of "$WETH" "$BOB" "$L1_RPC")"   "$(bn_sub "$b_weth0" 1000000000000000000)"
    expect_eq "bob USDC +2000"   "$(balance_of "$USDC" "$BOB" "$L1_RPC")"   "$(bn_add "$b_usdc0" 2000000000000000000000)"

    # I11 is an equality, not a bound. Stated as >= it would permit a settlement
    # to end holding more than it started with, which is exactly the shape an
    # unpaid user leaves behind (§9.1).
    expect_eq "executor USDC back to its opening balance (I11)" "$(balance_of "$USDC" "$EXECUTOR" "$L1_RPC")" "$x_usdc0"
    expect_eq "executor WETH back to its opening balance (I11)" "$(balance_of "$WETH" "$EXECUTOR" "$L1_RPC")" "$x_weth0"

    # A batch that nets exactly leaves nothing for the sweep.
    expect_eq "no residue swept: windfall WETH unchanged" "$(balance_of "$WETH" "$WINDFALL" "$L1_RPC")" "$w_weth0"
}

# ---------------------------------------------------------------------------
# Phase 2 -- liquidity sourced on L1 inside the dispatch
# ---------------------------------------------------------------------------

phase_route() {
    step "Phase 2: one intent, filled by routing through Uniswap V2 on L1"
    require_env ROUTER PAIR

    local dl sell buy_amount min_out a_usdc0 a_weth0 x_usdc0 x_weth0 w_weth0 sig_a id_a
    dl=$(( $(l2_now) + 86400 ))
    sell=2000000000000000000000              # 2,000 USDC
    # mulDiv(sellAmount, p[sell], p[buy]) at p = [1e18, 2100e18].
    buy_amount=952380952380952380            # ~0.95238 WETH
    min_out="$buy_amount"

    a_usdc0=$(balance_of "$USDC" "$ALICE" "$L1_RPC"); a_weth0=$(balance_of "$WETH" "$ALICE" "$L1_RPC")
    x_usdc0=$(balance_of "$USDC" "$EXECUTOR" "$L1_RPC"); x_weth0=$(balance_of "$WETH" "$EXECUTOR" "$L1_RPC")
    w_weth0=$(balance_of "$WETH" "$WINDFALL" "$L1_RPC")

    sig_a=$(sign_intent "$ALICE_KEY" "$ALICE" "$USDC" "$WETH" "$sell" 900000000000000000 "$dl" 1)
    id_a=$(submit_intent "$ALICE_KEY" "$ALICE" "$USDC" "$WETH" "$sell" 900000000000000000 "$dl" 1 "$sig_a")
    info "intent $id_a accepted on L2 (nonce 1)"

    # The route. `Executor` pulls before it interacts, so the batch funds the
    # swap and the solver needs no capital (§9). Two calls: the approval the
    # router needs, and the swap itself, with the output landing back in
    # `Executor` where `_pay` and `_restore` expect it.
    #
    # `minOut` is the user's payout rather than a percentage band, so the swap
    # reverts precisely when the pool has moved enough to make the batch
    # unpayable -- and the whole settlement unwinds on both chains rather than
    # failing later in `_pay` as a token error.
    #
    # Neither call may target `Relayer` (I12); the approval targets the token and
    # the swap targets the router.
    export CALL_TARGETS="$USDC,$ROUTER"
    export CALL_DATAS="$(cast calldata 'approve(address,uint256)' "$ROUTER" "$sell"),$(cast calldata \
        'swapExactTokensForTokens(uint256,uint256,address[],address,uint256)' \
        "$sell" "$min_out" "[$USDC,$WETH]" "$EXECUTOR" "$dl")"

    export TOKENS="$USDC,$WETH"
    export PRICES="$PRICE_SCALE,2100000000000000000000"
    export TRADE_ACCOUNTS="$ALICE"
    export TRADE_SELL_IDX="0"
    export TRADE_BUY_IDX="1"
    export TRADE_SELL_AMOUNTS="$sell"
    export TRADE_LIMITS="900000000000000000"
    export TRADE_DEADLINES="$dl"
    export TRADE_NONCES="1"
    export INTENT_IDS="$id_a"
    export SIGS="$sig_a"
    SALT=0x0000000000000000000000000000000000000000000000000000000000000002
    WITNESS_ACCOUNT="$ALICE"; WITNESS_NONCE=1

    settle_with_retry "route" 3 || return 1

    step "Phase 2 effects"
    expect_eq "intent $id_a is FILLED on L2" "$(intent_state "$id_a")" "2"
    expect_eq "alice nonce 1 consumed on L1 (I10)" "$(nonce_used_on_l1 "$ALICE" 1)" "true"
    expect_eq "alice USDC -2000" "$(balance_of "$USDC" "$ALICE" "$L1_RPC")" "$(bn_sub "$a_usdc0" "$sell")"
    expect_eq "alice WETH = mulDiv(sell, p[usdc], p[weth])" \
        "$(balance_of "$WETH" "$ALICE" "$L1_RPC")" "$(bn_add "$a_weth0" "$buy_amount")"

    expect_eq "executor USDC back to its opening balance (I11)" "$(balance_of "$USDC" "$EXECUTOR" "$L1_RPC")" "$x_usdc0"
    expect_eq "executor WETH back to its opening balance (I11)" "$(balance_of "$WETH" "$EXECUTOR" "$L1_RPC")" "$x_weth0"

    # I17: the swap returned more WETH than the price vector obliged the batch to
    # deliver, and the excess went somewhere the solver cannot name. A payload
    # that could nominate this destination would turn every unpaid user into
    # solver revenue with every balance check still passing (§9.1).
    local w_weth1
    w_weth1=$(balance_of "$WETH" "$WINDFALL" "$L1_RPC")
    if bn_gt "$w_weth1" "$w_weth0"; then
        pass "residue swept to windfallRecipient: +$(cast from-wei "$(bn_sub "$w_weth1" "$w_weth0")") WETH (I17)"
    else
        fail "residue was not swept: windfall WETH still $w_weth1"
    fi
    expect_eq "solver holds no WETH -- residue is unreachable by them (I17)" \
        "$(balance_of "$WETH" "$SOLVER" "$L1_RPC")" "0"
}

# ---------------------------------------------------------------------------

step "Settlement e2e against $KURTOSIS_ENCLAVE"
info "book     $BOOK (L2 $L2_CHAIN_ID)"
info "executor $EXECUTOR (L1 $L1_CHAIN_ID), via proxy $EXECUTOR_PROXY"
info "windfall $WINDFALL  (devnet placeholder; §13.2 is open)"
info "COMMIT_WINDOW ${COMMIT_WINDOW}s, REVEAL_WINDOW ${REVEAL_WINDOW}s  (§13.3 placeholders)"

case "$WHICH" in
    cow)   phase_cow ;;
    route) phase_route ;;
    all)   phase_cow; phase_route ;;
    *)     die "unknown phase '$WHICH' (want cow, route or all)" ;;
esac

step "Result"
if [ "$FAILURES" -eq 0 ]; then
    printf '    %sall checks passed%s\n' "$C_OK" "$C_0"
else
    printf '    %s%d check(s) failed%s\n' "$C_BAD" "$FAILURES" "$C_0"
fi
exit $((FAILURES > 0))
