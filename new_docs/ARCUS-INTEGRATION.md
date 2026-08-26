# Arcus integration — docs & endpoints (verified live 2026-08-02)

Handoff for the dev. Everything below was probed live; the /quote example is a real
response. Arcus = dYdX Labs × Robinhood Crypto DEX on chain 4663. Spot trades the
CANONICAL stock tokens (their addresses match our beacon-verified list).

## Docs
- Main docs: https://docs.arcus.xyz (machine index: https://docs.arcus.xyz/llms.txt)
- Spot overview: https://docs.arcus.xyz/concepts/spot-overview.md
- **Spot RFQ flow: https://docs.arcus.xyz/concepts/spot-rfq.md** ← the one to read
- Wrapped tokens (fallback fills): https://docs.arcus.xyz/concepts/wrapped-tokens.md
- API reference: https://docs.arcus.xyz/api-reference/introduction

## Base URLs
| Service | URL |
|---|---|
| Main API (perps, meta) | `https://api.arcus.xyz/v1/` |
| **Spot RFQ router** | `https://router.spot.arcus.xyz` |
| Spot indexer | `https://indexer.spot.arcus.xyz` |
| Staging / testnet | `api.staging.arcus.xyz` / `api.testnet.arcus.xyz`, `router.spot.testnet.arcus.xyz` |

## The endpoint that matters — spot RFQ quote (permissionless, no key)

```
GET https://router.spot.arcus.xyz/quote
    ?chainId=4663
    &sellToken=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168   (USDG, 6 dec)
    &buyToken=0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9    (AAPLx, 18 dec)
    &sellAmount=1000000000                                   (base units)
    &taker=0x...                                             (taker wallet)
```

Real response (trimmed): `{"recommended":"arcus","venue":"arcus","details":{"paths":
[{"proportionBps":10000,"hops":[{"protocol":"rfq","id":"maker-t",...}]}],
"buyAmount":"3232166521095222898","sellAmount":"1000000000",...}` — i.e. $1,000 →
3.2322 AAPL @ $309.39, RFQ maker fill.

**Execution flow** (from spot-rfq docs): indicative quote (above) → taker signs an
EIP-712 intent {chainId, sellToken, buyToken, sellAmount, taker, minBuyAmount,
nonce, deadline} with Permit2 → server collects firm maker quotes (makers never see
minBuyAmount), ranks by output, bundles winning signed quote + intent into ONE
atomic tx — all legs fill or none. Wire formats in the API reference.

## Useful supporting endpoints (all public, probed)
| Endpoint | Returns |
|---|---|
| `GET api.arcus.xyz/v1/api-meta/spot/overview` | spot universe with CANONICAL contract addresses + live quotes + financials |
| `GET api.arcus.xyz/v1/api-meta/markets` | market metadata (tickers, addresses, descriptions) |
| `GET api.arcus.xyz/v1/markets` | perp market specs (tick sizes, min/max order, oracle & mark price) |
| `GET api.arcus.xyz/v1/mids` | all perp mids (incl. HOOD-USD — perp only, no token exists) |
| `GET api.arcus.xyz/v1/l2OrderBook/{TICKER}-USD` | perp L2 book, e.g. `NVDA-USD` |
| `GET api.arcus.xyz/v1/bbo/{TICKER}-USD` | best bid/offer |

## Measured depth (RFQ quotes, 2026-08-02 — chart: ox-quotes/arcus_depth.png)
- **≤$100k per clip: +0.10–0.15% buy / −0.16–0.29% sell on EVERYTHING** (AAPL,
  NVDA, SPCX, SPY, TSLA, GOOGL, QQQ, SLV) — including names that are dust on
  Uniswap pools.
- Above $100k the maker declines and quotes fall to thin fallback — EXCEPT
  NVDA (good to $1M at ±2.3%) and SPCX ($250k at ~2%).
- Rule for our code: **clip everything at ≤$100k**, repeat clips (re-quoting is
  free). Genesis $450–500k ≈ 5 clips ≈ 0.15% total cost.

## Integration rules for our contracts/backend
1. **Zap + treasury desk + fire-escape execution all route here.** 0x is
   compliance-blocked for stocks (verified); Uniswap pools are the small-size
   fallback only.
2. **Native fills only:** for illiquid names Arcus may fill with a WRAPPED
   placeholder (e.g. wTSLA) that a maker settles to the real token later. Our pot
   must accept only canonical tokens — reject or hold-and-settle wrapped fills at
   the desk layer, never deposit them to the wrapper.
3. **Slippage guard:** always set minBuyAmount from the indicative quote minus
   tolerance; the atomic settle makes partial fills impossible — it's all-or-none.
4. **Geo:** the app has a `spot_geo_blocked` flag; the API quoted us freely.
   Confirm from the backend's egress region.
5. **PRE-LAUNCH TEST (blocking):** execute one real ~$100–1k trade end-to-end —
   verifies the settlement contract, Permit2 flow, native delivery, and
   indicative-vs-firm quote gap. Until then this rail is measured, not proven.

## Related references
- Canonical token list (194, beacon-verified method): ox-quotes/stock_tokens_full.json
- Chainlink feeds on 4663 (57 feeds, 35 equities, NO HOOD):
  https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json
- Uniswap pool depth for comparison: ox-quotes/depth_sweep.png · pool_ladder.py
- Issuer note: stock tokens issued by Bitstamp Global Ltd (BVI) — entity KYB at
  Bitstamp = direct issuer access (contact: vignesh.muralidharan@robinhood.com)
