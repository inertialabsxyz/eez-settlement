# Shared helpers for the devnet harness. Source after script/dev.env.
#
# Everything here exists because of a specific way this stack fails silently.
# The failures are catalogued in eez-ticket-sales/docs/eez-gotchas.md; the
# numbered references below point at it.

DEPLOYMENTS="${DEPLOYMENTS:-script/deployments.env}"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 1 ]; then C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_HDR=$'\033[1m'; C_0=$'\033[0m'
else C_OK=; C_BAD=; C_DIM=; C_HDR=; C_0=; fi

FAILURES=0

step()  { printf '\n%s==> %s%s\n' "$C_HDR" "$*" "$C_0"; }
info()  { printf '    %s\n' "$*"; }
note()  { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_0"; }
pass()  { printf '    %sPASS%s  %s\n' "$C_OK" "$C_0" "$*"; }
fail()  { printf '    %sFAIL%s  %s\n' "$C_BAD" "$C_0" "$*"; FAILURES=$((FAILURES + 1)); }
die()   { printf '\n%sfatal:%s %s\n' "$C_BAD" "$C_0" "$*" >&2; exit 1; }

# Assert two values are equal. Used for I11-style checks, where the spec is
# explicit that the assertion is an equality and not a bound (§10).
expect_eq() {
    local what="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then pass "$what = $got"
    else fail "$what: got $got, want $want"; fi
}

expect_ne() {
    local what="$1" got="$2" nope="$3"
    if [ "$got" != "$nope" ]; then pass "$what = $got"
    else fail "$what: got $got, which is exactly what it must not be"; fi
}

# ---------------------------------------------------------------------------
# Deployment record
# ---------------------------------------------------------------------------

record() {
    local k="$1" v="$2"
    # Last write wins on re-source, but keep the file readable by replacing in
    # place rather than appending duplicates.
    if [ -f "$DEPLOYMENTS" ] && grep -q "^${k}=" "$DEPLOYMENTS"; then
        grep -v "^${k}=" "$DEPLOYMENTS" > "$DEPLOYMENTS.tmp" && mv "$DEPLOYMENTS.tmp" "$DEPLOYMENTS"
    fi
    printf '%s=%s\n' "$k" "$v" >> "$DEPLOYMENTS"
    export "$k=$v"
    info "$k = $v"
}

require_env() {
    local k
    for k in "$@"; do
        [ -n "${!k:-}" ] || die "$k is unset. Run the earlier install script, or source $DEPLOYMENTS."
    done
}

# ---------------------------------------------------------------------------
# Cross-chain sending
# ---------------------------------------------------------------------------

# The front maintains its own nonce reservation, invisible to
# eth_getTransactionCount on the plain L2 RPC, and a cross-chain transaction
# reserves TWO of them. Reading the nonce from L2_RPC produces a value the front
# rejects as an underpriced replacement. (gotcha 4)
front_nonce() {
    local who="$1"
    curl -s --max-time 10 -X POST "$L2_FRONT" -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionCount\",\"params\":[\"$who\",\"pending\"],\"id\":1}" \
        | jq -r '.result // empty' | xargs -r cast to-dec 2>/dev/null || echo ""
}

# `cast gas-price` returns single-digit wei on this L2. Paired with a tip of 1,
# the effective priority after base fee is zero, so the front accepts the
# transaction and then quietly drops it. Bid far above the pool. (gotcha 5)
l2_gas_price() {
    local gp
    gp=$(cast gas-price --rpc-url "$L2_RPC")
    if [ $((gp * 4)) -gt 1000000000 ]; then echo $((gp * 4)); else echo 1000000000; fi
}

# Build a raw L2 transaction carrying `data` to `to` and post it to the outbound
# cross-chain front. Echoes the transaction hash.
#
# Gas cannot be estimated -- the remote leg is unsimulatable from here -- so the
# limit is explicit.
xsend() {
    local key="$1" from="$2" to="$3" data="$4" gaslimit="${5:-6000000}"
    local nonce gp tip raw resp hash

    nonce=$(front_nonce "$from")
    [ -n "$nonce" ] || { echo "front did not answer eth_getTransactionCount" >&2; return 1; }
    gp=$(l2_gas_price); tip=$((gp / 10))

    raw=$(cast mktx "$to" "$data" \
        --chain-id "$L2_CHAIN_ID" --private-key "$key" --nonce "$nonce" \
        --gas-limit "$gaslimit" --gas-price "$gp" --priority-gas-price "$tip")

    resp=$(curl -s --max-time 30 -X POST "$L2_FRONT" -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"$raw\"],\"id\":1}")
    hash=$(echo "$resp" | jq -r '.result // empty')
    [ -n "$hash" ] || { echo "front rejected the transaction: $resp" >&2; return 1; }
    echo "$hash"
}

# Block until the front's nonce for `who` moves past `want`.
#
# This means "the send is no longer in flight" and nothing stronger. The nonce
# moves on the front's own reservation schedule, ahead of the L1 state becoming
# readable, so it is NOT a "settled on both chains" signal -- §13.4 records a run
# that asserted the moment it moved, read an L1 that had not caught up, and
# reported six failures for a settlement that had landed. Wait on an L1 fact.
# (gotcha 4)
wait_settled() {
    local who="$1" want="$2" timeout="${3:-120}" i n
    for i in $(seq 1 "$timeout"); do
        n=$(front_nonce "$who")
        if [ -n "$n" ] && [ "$n" -gt "$want" ] 2>/dev/null; then return 0; fi
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# Arithmetic
# ---------------------------------------------------------------------------
# Token amounts here are 18-decimal, so a 2,000-token leg is 2e21 and shell
# `$(( ))` -- which is 64-bit, topping out near 9.2e18 -- wraps it into a
# plausible-looking wrong number. The first run of this harness reported
# "want 7751640039368425472" for a balance of 2000 ether. Do the arithmetic in
# Python.

bn() { python3 -c "print($1)"; }
bn_sub() { bn "int('$1') - int('$2')"; }
bn_add() { bn "int('$1') + int('$2')"; }
bn_gt()  { [ "$(bn "int('$1') > int('$2')")" = "True" ]; }

# ---------------------------------------------------------------------------
# Chain reads
# ---------------------------------------------------------------------------

l2_now() { cast block latest --field timestamp --rpc-url "$L2_RPC"; }
l1_now() { cast block latest --field timestamp --rpc-url "$L1_RPC"; }

balance_of() { cast call "$1" 'balanceOf(address)(uint256)' "$2" --rpc-url "$3" | awk '{print $1}'; }

# Wait until the L2 clock reaches `ts`. Polls the chain rather than the host: the
# devnet's clock is its own, and `revealAndExecute` compares against
# `block.timestamp`, not against the wall.
wait_until_l2() {
    local ts="$1" now
    while :; do
        now=$(l2_now)
        [ "$now" -ge "$ts" ] 2>/dev/null && return 0
        sleep 2
    done
}
