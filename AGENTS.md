# Docs

Two directories, split by audience:

- **`agent-docs/`** — written for agents. Feature and design docs that track the code in `src/`.
  These are the ones you read and update.
- **`human-docs/`** — written for people: the protocol handbook, the implementation plan, the
  conformance review, the plain-language walkthrough, the generous-auction paper (`.md`, `.tex`,
  `.pdf`, build artifacts), the interactive model `index.html`, and the spec diagrams
  (`image.png`, `MONOLITHIC.excalidraw`). Read them as reference; do not rewrite them to match
  code.

The only doc left at the repo root is `README.md`, which is Foundry boilerplate.

## Scope

**`src/GenerousAuction.sol` is the only contract under active work.** Do not touch
`src/MonoAuction.sol`, `src/interfaces/IMonoAuction.sol`, or its tests — not even to keep them
consistent with a change made to `GenerousAuction`. The two are allowed to diverge. If a change
looks like it belongs in both, make it in `GenerousAuction` only and say so.

## Rules for agents

0. **Always read [SmartContractsGuide.md](agent-docs/SmartContractsGuide.md) first** — before writing or changing any contract in `src/`. It carries the conventions every contract must follow (interfaces, file layout, naming).
1. **Read first** — Before changing behavior in code, open the matching doc under `agent-docs/` and use it as the source of truth for how the feature is supposed to work.
2. **Update the doc** — When you change a feature, update the doc that describes it in the same change. Code and docs must not drift.
3. **Add a doc for new features** — New subsystems get a new markdown file in `agent-docs/` (e.g. `agent-docs/Foo.md`). Link or mention it here if useful.

## Index

| Doc | Covers |
|-----|--------|
| [SmartContractsGuide.md](agent-docs/SmartContractsGuide.md) | **Read first.** Conventions for every contract in `src/` |
| [Mono.md](agent-docs/Mono.md) | The MONO reserve token and its INDEX vault in `src/Mono.sol` |
| [MonoAuction.md](agent-docs/MonoAuction.md) | Pay-as-bid tick-book auction in `src/MonoAuction.sol` |
| [GenerousAuction.md](agent-docs/GenerousAuction.md) | Single-sale version of the same mechanism in `src/GenerousAuction.sol` |
| [Index.md](agent-docs/Index.md) | In-kind basket wrapper and deficit reallocation channel in `src/Index.sol` |

Human reference, for context only:

| Doc | Covers |
|-----|--------|
| [HANDBOOK.md](human-docs/HANDBOOK.md) | The whole protocol — the single spec reference |
| [implementation.md](human-docs/implementation.md) | Implementation plan and source-of-truth order |
| [discrepancies.md](human-docs/discrepancies.md) | Spec vs. code conformance review |
| [doc.md](human-docs/doc.md) | Plain-language walkthrough of the auction |
| [generous-auction.md](human-docs/generous-auction.md) | The distribution rule and its derivation (`.tex`/`.pdf` alongside) |
