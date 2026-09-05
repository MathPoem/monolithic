// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../src/GenerousAuction.sol";
import {Mono} from "../src/Mono.sol";
import {IGenerousAuction} from "../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {MockPool} from "./MockPool.sol";
import {TestERC20} from "./TestERC20.sol";

/// Random walks over the whole surface — bid, withdraw, stake, unstake, claim, claimAndStake,
/// sync, time — with the money and structure invariants checked after every step. The
/// deterministic anchors (A.9, the §5 stake split, the two-level waterfall) pin exact numbers;
/// this suite pins that NO reachable sequence breaks conservation, custody, or the heap.
contract GenerousHandler is Test {
    GenerousAuction public auction;
    Mono public mono;
    TestERC20 public cur;

    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint64 internal constant K = 100;

    address[6] public actors;
    uint256[5] public prices;

    // Ghosts: every unit of value that crossed the boundary, by direction.
    uint256 public deposited; // currency in via bids
    uint256 public refunded; // currency out via withdrawals
    uint256 public claimedTokens; // MONO out via claims (both flavours)
    uint256 public navHigh; // NAV high-water: must never fall

    constructor(GenerousAuction auction_, Mono mono_, TestERC20 cur_) {
        auction = auction_;
        mono = mono_;
        cur = cur_;
        for (uint256 i; i < 6; ++i) {
            actors[i] = address(uint160(0xAA00 + i));
        }
        for (uint256 i; i < 5; ++i) {
            prices[i] = FLOOR + i * SPACING;
        }
        navHigh = mono.nav();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 6];
    }

    /// NAV monotonicity is asserted here, on every step, rather than as an invariant — it is a
    /// high-water property, and the handler is where the water rises.
    function _navCheck() internal {
        uint256 nav = mono.nav();
        assertGe(nav, navHigh, "NAV fell");
        navHigh = nav;
    }

    function opBid(uint256 actorSeed, uint256 priceSeed, uint96 rawAmt) external {
        address who = _actor(actorSeed);
        if (auction.stakes(who) == 0) return; // the strict rule would just revert
        uint256 price = prices[priceSeed % 5];
        (uint256 held,,,,,) = auction.positions(who);
        if (held != 0 && held != price) {
            (uint256 live,) = auction.positionOf(who);
            if (live != 0) price = held; // one bid per owner: top up instead of reverting
        }
        uint128 amount = uint128(bound(uint256(rawAmt), 2e18, 500e18));

        // The exact predecessor hint: walk down the small fixed grid.
        uint256 prev = FLOOR;
        for (uint256 i; i < 5; ++i) {
            (,,,,,, bool init) = auction.ticks(prices[i]);
            if (init && prices[i] < price && prices[i] > prev) prev = prices[i];
        }

        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        try auction.submitBid(price, amount, who, prev) {
            deposited += amount;
        } catch {}
        vm.stopPrank();
        _navCheck();
    }

    function opWithdraw(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        (uint256 live,) = auction.positionOf(who);
        if (live == 0) return;
        vm.prank(who);
        try auction.withdrawBid() returns (uint256 out) {
            refunded += out;
        } catch {}
        _navCheck();
    }

    function opStake(uint256 actorSeed, uint96 rawAmt) external {
        address who = _actor(actorSeed);
        uint256 amount = bound(uint256(rawAmt), 1e15, 50e18);
        if (mono.balanceOf(address(this)) < amount) return;
        mono.transfer(who, amount);
        vm.startPrank(who);
        mono.approve(address(auction), amount);
        try auction.stake(amount) {} catch {}
        vm.stopPrank();
        _navCheck();
    }

    function opUnstake(uint256 actorSeed, uint96 rawAmt) external {
        address who = _actor(actorSeed);
        uint256 have = auction.stakes(who);
        if (have == 0) return;
        uint256 amount = bound(uint256(rawAmt), 1, have);
        vm.prank(who);
        try auction.unstake(amount) {} catch {}
        _navCheck();
    }

    function opClaim(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        try auction.claim(who) returns (uint256 got) {
            claimedTokens += got;
        } catch {}
        _navCheck();
    }

    function opClaimAndStake(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        uint256 balBefore = mono.balanceOf(who);
        vm.prank(who);
        try auction.claimAndStake() returns (uint256 got) {
            // Either staked in place or (in a lock window) paid out — both leave the contract
            // solvent; only what actually LEFT counts as claimed for custody accounting.
            claimedTokens += mono.balanceOf(who) - balBefore;
            got;
        } catch {}
        _navCheck();
    }

    function opSync(uint96 budget) external {
        auction.sync(bound(uint256(budget), 1, 300));
        _navCheck();
    }

    function opRoll(uint8 roundsSeed) external {
        vm.roll(block.number + (uint256(roundsSeed) % 3) * K + 1);
    }

    // ---------------------------------------------------------------- read helpers

    function actorCount() external pure returns (uint256) {
        return 6;
    }

    function priceCount() external pure returns (uint256) {
        return 5;
    }
}

/// forge-config: default.invariant.runs = 15
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = false
contract GenerousInvariantsTest is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;
    GenerousHandler internal handler;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint64 internal constant K = 100;

    function setUp() public {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));

        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: Q96 / 2,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: 40e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));

        handler = new GenerousHandler(auction, mono, cur);
        mono.transfer(address(handler), 5_000e18); // the stake pool the handler hands out
        targetContract(address(handler));
    }

    /// Guards the suite against vacuity: a scripted pass through the handler must actually move
    /// value, or every invariant above would hold over a book where nothing ever happened.
    function test_handlerMovesValue() public {
        handler.opStake(0, 10e18);
        handler.opStake(1, 10e18);
        handler.opBid(0, 2, 100e18);
        handler.opBid(1, 2, 100e18);
        handler.opRoll(4);
        handler.opSync(100);
        handler.opClaim(0);
        handler.opWithdraw(1);
        handler.opClaimAndStake(1);

        assertGt(handler.deposited(), 0, "bids landed");
        assertGt(handler.refunded(), 0, "a withdrawal landed");
        assertGt(handler.claimedTokens(), 0, "a claim paid");
        assertGt(auction.tokensSold(), 0, "the book absorbed emission");
    }

    /// Stake is custody: whatever else happens, the contract holds at least the stake.
    function invariant_stakeCustody() external view {
        assertGe(mono.balanceOf(address(auction)), auction.totalStaked(), "stake was spent");
    }

    /// Currency is conserved to the wei: everything that came in is still here, was refunded,
    /// or was paid into the vault by a pack. There is no fourth door.
    function invariant_currencyConserved() external view {
        assertEq(
            cur.balanceOf(address(auction)),
            handler.deposited() - handler.refunded() - auction.currencyMinted(),
            "escrow leaked"
        );
    }

    /// Tokens flow one way through three gates, each no wider than the last.
    function invariant_tokenGates() external view {
        assertLe(handler.claimedTokens(), auction.tokensMinted(), "paid out more than was minted");
        assertLe(auction.tokensMinted(), auction.tokensSold(), "minted more than was sold");
        assertLe(auction.tokensSold(), auction.saleSupply(), "sold past the sale size");
    }

    /// What the positions think they are owed never exceeds the pot that backs them — up to
    /// per-segment flooring dust: a position reads its consumption with ONE floor over its whole
    /// span, while the pour books each segment's floor separately, so the sum can run a few wei
    /// ahead. `claim` clamps `owed` to `tokensUnclaimed`, so the dust is uncollectable, never
    /// insolvent; the slack here is that bound, not a fudge.
    function invariant_owedCovered() external view {
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            (, uint256 owed) = auction.positionOf(handler.actors(i));
            sum += owed;
        }
        assertLe(sum, auction.tokensUnclaimed() + 1_000, "positions owed more than the unclaimed pot");
    }

    /// The fix for the flooring-remainder finding, held as an invariant: escrow actually held
    /// covers every position's live escrow. The slack is the documented death-segment residue
    /// (see the ponytail in the contract header): each death can book up to a token-wei more
    /// than its positions crystallise — one-sided, bounded, and dwarfed by the seed-dust remedy.
    function invariant_escrowSolvent() external view {
        uint256 sumLive;
        for (uint256 i; i < 6; ++i) {
            (uint256 live,) = auction.positionOf(handler.actors(i));
            sumLive += live;
        }
        assertGe(cur.balanceOf(address(auction)) + 1_000, sumLive, "live escrow not covered by balance");
    }

    /// Every tick's heap is well-formed: sizes match the seat list, seats point back at their
    /// index, and every parent's kappa is at most its children's.
    function invariant_heapWellFormed() external view {
        for (uint256 pi; pi < 5; ++pi) {
            uint256 price = FLOOR + pi * SPACING;
            address[] memory seats = auction.tickPositions(price);
            (,,,,, uint32 heapSize,) = auction.ticks(price);
            assertEq(seats.length, heapSize, "seat list vs heapSize");
            for (uint256 i; i < seats.length; ++i) {
                (uint256 pPrice,,,, uint256 kappa, uint32 idx) = auction.positions(seats[i]);
                assertEq(idx, i + 1, "seat points at its index");
                assertEq(pPrice, price, "seat belongs to this tick");
                if (i > 0) {
                    (,,,, uint256 parentKappa,) = auction.positions(seats[(i + 1) / 2 - 1]);
                    assertLe(parentKappa, kappa, "heap order violated");
                }
            }
        }
    }
}
