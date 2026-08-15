# Smart contracts guide

Conventions every contract in `src/` must follow. Read this before writing or changing a
contract, alongside the feature doc for the thing you are touching.

## Interfaces

**Every contract has a corresponding interface, and the contract inherits it.**

| Rule | |
| --- | --- |
| Location | `src/interfaces/` |
| Name | the contract's name prefixed with `I` — `GenerousAuction.sol` → `src/interfaces/IGenerousAuction.sol` |
| Inheritance | the contract declares `contract GenerousAuction is IGenerousAuction, ...` |

**The interface holds all structs and events.** They are declared there once and referenced
from the contract, not duplicated. Errors belong there too — they are part of the ABI a caller
has to decode.

What lives where:

| | interface | contract |
| --- | --- | --- |
| `struct` | ✅ declared | referenced |
| `event` | ✅ declared | emitted |
| `error` | ✅ declared | reverted |
| external / public function signatures | ✅ declared | implemented with `override` |
| constants, immutables, storage | — | ✅ |
| internal functions and internal-only types | — | ✅ |

A type used only inside the implementation and never crossing the ABI boundary stays in the
contract. Everything a caller or an indexer needs to know about is in the interface.

```solidity
// src/interfaces/IGenerousAuction.sol
interface IGenerousAuction {
    struct Tick { uint256 next; uint256 prev; uint256 demand; uint256 survival; uint64 epoch; bool init; }

    event BidSubmitted(address indexed owner, uint256 indexed price, uint128 amount);

    error NoOpenRound();

    function submitBid(uint256 price, uint128 amount, address owner, uint256 prevTick) external;
}

// src/GenerousAuction.sol
contract GenerousAuction is IGenerousAuction, ReentrancyGuardTransient {
    function submitBid(uint256 price, uint128 amount, address owner, uint256 prevTick)
        external
        override
        nonReentrant
    { ... }
}
```

Why: callers and tests integrate against the interface rather than the implementation, the ABI
has one definition instead of two that can drift, and the interface doubles as the reviewable
summary of the contract's public surface.

## Docs

Per `CLAUDE.md`: every subsystem has a doc in `agent-docs/`, and a behaviour change updates the
doc in the same commit.
