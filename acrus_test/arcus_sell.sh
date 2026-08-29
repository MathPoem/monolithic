#!/usr/bin/env bash
# Drive one Arcus spot RFQ sale out of an ArcusVault, end to end.
#
#   ./acrus_test/arcus_sell.sh deploy        deploy a vault, print the address for .env
#   ./acrus_test/arcus_sell.sh fund          move the position into the vault
#   ./acrus_test/arcus_sell.sh quote         price the sale, change nothing
#   ./acrus_test/arcus_sell.sh sell          quote -> arm -> submit -> poll   (REAL TRADE)
#   ./acrus_test/arcus_sell.sh status <tx>   poll a submitted swap
#   ./acrus_test/arcus_sell.sh balances      what the vault and wallet hold
#
# Reads RFQ_VAULT_ADDRESS / SELL_TOKEN / SELL_AMOUNT_RAW / WALLET_* / RPC_URL_4663 from .env.
# `sell` asks before each on-chain step; ARCUS_YES=1 skips the prompts.
#
# ponytail: curl + jq + cast, no node_modules. The router is plain HTTP and the only signing this
# flow needs is one `cast send` — a JS client would be a dependency tree to do the same four calls.
set -euo pipefail
cd "$(dirname "$0")/.."

# Parsed, never sourced: .env holds a key whose name starts with a digit, which no shell will take.
# A real environment variable wins, so a one-off run can point at a different vault without
# editing .env — the secrets stay in the file and only the addresses move.
env_get() {
    eval "local override=\${$1-}"
    if [ -n "${override:-}" ]; then printf '%s' "$override"; return; fi
    grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'
}

ROUTER=https://router.spot.arcus.xyz
CHAIN_ID=4663
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
SETTLEMENT=0x006102b16A04c20306A28b652745D3973D7D24fa
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168

RPC=$(env_get RPC_URL_4663)
VAULT=$(env_get RFQ_VAULT_ADDRESS)
WALLET=$(env_get WALLET_ADDRESS)
PK=$(env_get WALLET_PRIVATE_KEY)
SELL=$(env_get SELL_TOKEN)
AMT=$(env_get SELL_AMOUNT_RAW)
BUY=${BUY_TOKEN:-$USDG}
SLIPPAGE_BPS=${SLIPPAGE_BPS:-50}
# 65 bytes of filler: r=1, s=1, v=27. See the note at the submit step for why it is not "0x".
FILLER_SIG=0x000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000011b
: "${RPC:?RPC_URL_4663 missing from .env}"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
# ponytail: macOS still ships bash 3.2, which has no ${var,,}.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
confirm() {
    [ "${ARCUS_YES:-0}" = "1" ] && return 0
    # Without a tty `read` takes EOF and the abort is invisible — say so instead of dying quietly.
    if [ ! -t 0 ]; then
        printf 'no tty, cannot ask: %s\nre-run with ARCUS_YES=1 to approve up front.\n' "$1" >&2
        exit 1
    fi
    read -r -p "$1 [y/N] " a; [ "$a" = "y" ] || { echo "aborted"; exit 1; }
}

# ---------------------------------------------------------------- quote

get_quote() {
    curl -sS -m 40 -G "$ROUTER/v1/quote" \
        --data-urlencode "chainId=$CHAIN_ID" \
        --data-urlencode "sellToken=$SELL" \
        --data-urlencode "buyToken=$BUY" \
        --data-urlencode "sellAmount=$AMT" \
        --data-urlencode "taker=$VAULT" \
        --data-urlencode "allowWrapped=false" \
        --data-urlencode "slippageBps=$SLIPPAGE_BPS" \
        -o "$WORK/q.json"
    jq -e '.all[] | select(.venue == "arcus")' "$WORK/q.json" > "$WORK/arcus.json" \
        || { echo "no arcus quote:"; jq . "$WORK/q.json"; exit 1; }
}

# The quote is the counterparty's number. Check every field that ends up inside the digest, so a
# router that quietly changed the taker, the spender, or the wrapped flag cannot get signed.
check_quote() {
    local m; m=$(jq -r '.toSign.message' "$WORK/arcus.json")
    chk() {
        local got want; got=$(jq -r "$2" <<<"$m"); want=$3
        [ "$(lower "$got")" = "$(lower "$want")" ] || { echo "quote mismatch: $1 = $got, expected $want"; exit 1; }
    }
    [ "$(jq -r '.toSign.primaryType' "$WORK/arcus.json")" = "PermitWitnessTransferFrom" ] \
        || { echo "unexpected primaryType"; exit 1; }
    chk spender             '.spender'              "$SETTLEMENT"
    chk permitted.token     '.permitted.token'      "$SELL"
    chk permitted.amount    '.permitted.amount'     "$AMT"
    chk witness.taker       '.witness.taker'        "$VAULT"
    chk witness.sellToken   '.witness.takerSellToken' "$SELL"
    chk witness.buyToken    '.witness.takerBuyToken'  "$BUY"
    chk witness.sellAmount  '.witness.sellAmount'   "$AMT"
    chk witness.allowWrapped '.witness.allowWrapped' "false"
    # The permit and the witness share one nonce/deadline; the vault hashes them once for both.
    chk witness.nonce       '.witness.nonce'        "$(jq -r '.nonce' <<<"$m")"
    chk witness.deadline    '.witness.deadline'     "$(jq -r '.deadline' <<<"$m")"
}

show_quote() {
    local dec buy_dec
    dec=$(cast call "$SELL" 'decimals()(uint8)' --rpc-url "$RPC")
    buy_dec=$(cast call "$BUY" 'decimals()(uint8)' --rpc-url "$RPC")
    say "quote"
    jq -r --arg d "$dec" --arg bd "$buy_dec" '
      "  sell     : \(.sellAmount) raw (\($d) dec)",
      "  buy      : \(.buyAmount) raw (\($bd) dec)",
      "  floor    : \(.toSign.message.witness.minBuyAmount) raw",
      "  expires  : \(.expiry)",
      "  route    : \([.details.paths[].hops[] | "\(.protocol)/\(.id)"] | join(" + "))"
    ' "$WORK/arcus.json"
    jq -r '"  reference: \(.referencePrice // "n/a") (\(.referencePriceSource // "-"))"' "$WORK/q.json"
    echo "  seconds left: $(( $(jq -r '.expiry' "$WORK/arcus.json") - $(date +%s) ))"
}

# ---------------------------------------------------------------- digest

# Rebuild the Permit2 digest from the quote using cast only. This is deliberately a second
# implementation: the vault computes the same digest in Solidity, and `sell` refuses to submit
# unless the two agree. One of them being wrong is then a stop, not a signed bad intent.
compute_digest() {
    local m nonce deadline minbuy tp ti pw ds tph wit sh
    m=$(jq -r '.toSign.message' "$WORK/arcus.json")
    nonce=$(jq -r '.nonce' <<<"$m")
    deadline=$(jq -r '.deadline' <<<"$m")
    minbuy=$(jq -r '.witness.minBuyAmount' <<<"$m")

    tp=$(cast keccak "TokenPermissions(address token,uint256 amount)")
    ti=$(cast keccak "TakerIntent(address taker,address takerSellToken,address takerBuyToken,uint256 sellAmount,uint256 minBuyAmount,bool allowWrapped,uint256 nonce,uint256 deadline)")
    pw=$(cast keccak "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,TakerIntent witness)TakerIntent(address taker,address takerSellToken,address takerBuyToken,uint256 sellAmount,uint256 minBuyAmount,bool allowWrapped,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)")
    ds=$(cast call "$PERMIT2" 'DOMAIN_SEPARATOR()(bytes32)' --rpc-url "$RPC")

    tph=$(cast keccak "$(cast abi-encode 'f(bytes32,address,uint256)' "$tp" "$SELL" "$AMT")")
    wit=$(cast keccak "$(cast abi-encode 'f(bytes32,address,address,address,uint256,uint256,bool,uint256,uint256)' \
        "$ti" "$VAULT" "$SELL" "$BUY" "$AMT" "$minbuy" false "$nonce" "$deadline")")
    sh=$(cast keccak "$(cast abi-encode 'f(bytes32,bytes32,address,uint256,uint256,bytes32)' \
        "$pw" "$tph" "$SETTLEMENT" "$nonce" "$deadline" "$wit")")

    echo "$nonce $deadline $minbuy $(cast keccak "$(cast concat-hex 0x1901 "$ds" "$sh")")"
}

# ---------------------------------------------------------------- commands

cmd_deploy() {
    : "${PK:?WALLET_PRIVATE_KEY missing from .env}"
    confirm "deploy ArcusVault(owner=$WALLET, settlement=$SETTLEMENT) to chain $CHAIN_ID?"
    FOUNDRY_PROFILE=arcus forge create acrus_test/ArcusVault.sol:ArcusVault \
        --rpc-url "$RPC" --private-key "$PK" --broadcast \
        --constructor-args "$WALLET" "$SETTLEMENT"
    echo "put the deployed address in .env as RFQ_VAULT_ADDRESS"
}

cmd_balances() {
    say "balances"
    for who in "$VAULT" "$WALLET"; do
        [ -n "$who" ] || continue
        printf '  %s  sell=%s  buy=%s  gas=%s\n' "$who" \
            "$(cast call "$SELL" 'balanceOf(address)(uint256)' "$who" --rpc-url "$RPC" | cut -d' ' -f1)" \
            "$(cast call "$BUY"  'balanceOf(address)(uint256)' "$who" --rpc-url "$RPC" | cut -d' ' -f1)" \
            "$(cast balance "$who" --rpc-url "$RPC")"
    done
    echo "  armed: $(cast call "$VAULT" 'armed()(bytes32)' --rpc-url "$RPC")"
}

# The position starts split between the wallet and OLD_VAULT_ADDRESS — the 0x AllowanceHolder
# vault from the earlier (compliance-blocked) attempt. `rescue(token,to,amount)` is that
# contract's own owner-only exit; the argument order is confirmed by simulation, the swapped
# order reverts with TransferFailed.
cmd_fund() {
    : "${VAULT:?RFQ_VAULT_ADDRESS missing from .env}"
    : "${PK:?WALLET_PRIVATE_KEY missing from .env}"
    local old old_bal wallet_bal
    old=$(env_get OLD_VAULT_ADDRESS)

    if [ -n "$old" ]; then
        old_bal=$(cast call "$SELL" 'balanceOf(address)(uint256)' "$old" --rpc-url "$RPC" | cut -d' ' -f1)
        if [ "$old_bal" != "0" ]; then
            confirm "rescue $old_bal raw of $SELL out of the old 0x vault $old?"
            cast send "$old" 'rescue(address,address,uint256)' "$SELL" "$WALLET" "$old_bal" \
                --rpc-url "$RPC" --private-key "$PK" >/dev/null
            echo "rescued $old_bal"
        fi
    fi

    wallet_bal=$(cast call "$SELL" 'balanceOf(address)(uint256)' "$WALLET" --rpc-url "$RPC" | cut -d' ' -f1)
    [ "$wallet_bal" != "0" ] || { echo "wallet holds none of $SELL"; exit 1; }
    confirm "move all $wallet_bal raw of $SELL into the vault $VAULT?"
    cast send "$SELL" 'transfer(address,uint256)' "$VAULT" "$wallet_bal" \
        --rpc-url "$RPC" --private-key "$PK" >/dev/null

    cmd_balances
    echo
    echo "set SELL_AMOUNT_RAW in .env to the vault's balance above, or leave it empty to sell all."
}

# An empty SELL_AMOUNT_RAW means "whatever the vault holds" — one less number to keep in sync.
resolve_amt() {
    : "${VAULT:?RFQ_VAULT_ADDRESS missing from .env}"
    if [ -z "$AMT" ]; then
        AMT=$(cast call "$SELL" 'balanceOf(address)(uint256)' "$VAULT" --rpc-url "$RPC" | cut -d' ' -f1)
        echo "sell amount: $AMT raw (the vault's whole balance)"
    fi
    [ "$AMT" != "0" ] || { echo "nothing to sell"; exit 1; }
}

cmd_quote() { resolve_amt; get_quote; check_quote; show_quote
    read -r _ _ _ digest <<<"$(compute_digest)"; echo "  digest   : $digest"; }

cmd_status() {
    local tx=$1
    # The tx hash goes in as `id`, and `venue` is required — pass neither correctly and the router
    # answers STATUS_ID_REQUIRED / INVALID_STATUS_VENUE and every poll reads as unknown.
    curl -sS -m 30 -G "$ROUTER/v1/status" --data-urlencode "id=$tx" \
        --data-urlencode "chainId=$CHAIN_ID" --data-urlencode "venue=arcus" | jq .
}

cmd_sell() {
    : "${PK:?WALLET_PRIVATE_KEY missing from .env}"
    resolve_amt

    get_quote; check_quote; show_quote
    local nonce deadline minbuy digest vault_digest
    read -r nonce deadline minbuy digest <<<"$(compute_digest)"
    say "digest (cast): $digest"

    # Ask the vault what it makes of the same terms before spending gas on it.
    vault_digest=$(cast call "$VAULT" \
        'arm(address,address,uint256,uint256,uint256,uint256)(bytes32)' \
        "$SELL" "$BUY" "$AMT" "$minbuy" "$nonce" "$deadline" \
        --from "$WALLET" --rpc-url "$RPC")
    echo "digest (vault): $vault_digest"
    [ "$(lower "$digest")" = "$(lower "$vault_digest")" ] || { echo "DIGEST MISMATCH — not submitting"; exit 1; }

    confirm "arm the vault and sell $AMT raw of $SELL for >= $minbuy raw of $BUY?"
    cast send "$VAULT" 'arm(address,address,uint256,uint256,uint256,uint256)' \
        "$SELL" "$BUY" "$AMT" "$minbuy" "$nonce" "$deadline" \
        --rpc-url "$RPC" --private-key "$PK" >/dev/null
    echo "armed on-chain, $(( deadline - $(date +%s) ))s before the quote expires"

    say "submitting"
    # The signature bytes are filler and must be exactly 65 of them. Permit2 sends a contract
    # owner down the ERC-1271 branch and hands these bytes to `isValidSignature`, which ignores
    # them — the vault's `armed` slot is the real signature. They still have to be *there*: the
    # router rejects "0x" with ARCUS_SUBMIT_FIELDS_REQUIRED, and anything not 65/64 bytes long
    # would trip Permit2's own length check on the EOA path. r=s=1, v=27 is the cheapest shape
    # that satisfies both without pretending to be a real signature.
    jq -c --arg taker "$VAULT" --arg buy "$BUY" --arg sig "$FILLER_SIG" \
        '{venue:"arcus", chainId:'"$CHAIN_ID"', taker:$taker, signature:$sig,
          buyToken:$buy, routeTag:"arcus-vault-probe", typedData:.toSign}' \
        "$WORK/arcus.json" > "$WORK/submit.json"
    curl -sS -m 60 -X POST "$ROUTER/v1/submit" \
        -H 'content-type: application/json' --data @"$WORK/submit.json" | tee "$WORK/res.json" | jq .

    local tx; tx=$(jq -r '.txHash // empty' "$WORK/res.json")
    [ -n "$tx" ] || { echo "no txHash returned"; exit 1; }
    say "polling $tx"
    for _ in $(seq 1 20); do
        local s; s=$(cmd_status "$tx"); echo "$s" | jq -c '{status:(.status//.state//"?")}'
        case "$(jq -r '.status // .state // ""' <<<"$s")" in
            success|filled|confirmed|failed|reverted) break ;;
        esac
        sleep 3
    done
    cmd_balances
}

case "${1:-}" in
    deploy)   cmd_deploy ;;
    fund)     cmd_fund ;;
    quote)    cmd_quote ;;
    sell)     cmd_sell ;;
    status)   cmd_status "${2:?usage: status <txHash>}" ;;
    balances) cmd_balances ;;
    *) sed -n '2,15p' "$0"; exit 1 ;;
esac
