// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

/// HAZARD: the constructor bounds `startBlock` only on the FUTURE side (src/GenerousAuction.sol
/// L220-222: `startBlock > block.number + 2_628_000` reverts). A `startBlock` in the PAST is
/// accepted with no lower bound at all, and `_emittedAt` (L322-337) accrues from it in closed
/// form, clamped only at `saleSupply` (`due()`, L299-306). The deploy script's own comment
/// (script/DeployGenerousAuction.s.sol L100-101) says a START_BLOCK in the past "is not fatal -
/// it just accrues a backlog that the first sync releases in one lump". That lump is handed to
/// the first seated position at ITS price: with the script's schedule (100 MONO / 15 L1 blocks)
/// a START_BLOCK stale by ~2.3 days puts 100% of `saleSupply` in `due()` at deploy, and the
/// first bidder - 1 wei of stake, a bid at the floor - takes the entire sale at NAV in one
/// block, with a 25% pool premium standing. Round-6 #17 measured 7.7% for a dry week mid-sale;
/// this is the whole sale, at deploy, from a documented-as-harmless config.
contract Review7ConfigStaleStartBlock is Review7ConfigBase {
    uint64 internal constant K = 15;
    uint128 internal constant R = 100e18;
    uint256 internal constant DAY_L1 = 6_950; // the script's own conversion table

    function _deployStale(uint256 staleBy) internal {
        vm.roll(100_000);
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.roundBlocks = K;
        c.emissionPerRound = R;
        c.startBlock = uint64(block.number - staleBy);
        _deployWith(c);
    }

    /// BUG-form: a sale must not open with its whole supply already owed. FAILS on current code.
    function test_BUG_staleStart_wholeSaleDueAtDeploy() public {
        _deployStale(16_000); // ~2.3 days of L1 blocks
        emit log_named_uint("saleSupply", auction.saleSupply());
        emit log_named_uint("due() at deploy", auction.due());
        emit log_named_uint("emittedToDate() at deploy", auction.emittedToDate());
        assertEq(auction.due(), 0, "BUG: constructor accepted a stale startBlock; 100% of saleSupply is due at deploy");
    }

    /// Characterisation of the lump: one bidder, 1 wei of stake, bid at the floor, takes the whole
    /// sale in the first sync and can immediately sell into a 25% premium.
    function test_staleStart_firstBidderTakesWholeSaleAtFloor() public {
        _deployStale(16_000);
        uint256 supply = auction.saleSupply();
        assertEq(auction.due(), supply, "everything is owed before the first block passes");

        _stakeFor(aa, 1); // dust stake is enough: the strict rule only needs s > 0
        _bid(aa, 1e18, uint128(supply), 1e18); // escrow exactly enough to buy all of it at NAV
        auction.sync(64);

        emit log_named_uint("first bidder owed", _owed(aa));
        emit log_named_uint("remaining()", auction.remaining());
        assertEq(_owed(aa), supply, "the whole sale, in one sync, to one bidder at the floor");
        assertEq(auction.remaining(), 0, "sold out in the deploy block");

        // Paper profit against the pool price the premium gate read.
        uint256 poolValue = supply * 1.25e18 / 1e18;
        emit log_named_uint("paid (INDEX)", supply);
        emit log_named_uint("worth at pool price (INDEX)", poolValue);
        assertGt(poolValue, supply * 124 / 100, ">24% of the sale's value handed to the first bidder");
    }

    /// One day stale - the script's suggested "read it from chain, add 20 blocks" workflow with a
    /// day between reading and broadcasting - still hands ~44% of the sale to the first bidder.
    function test_staleStart_oneDayStale_isFortyFourPercent() public {
        _deployStale(DAY_L1);
        uint256 supply = auction.saleSupply();
        uint256 share = auction.due() * 10_000 / supply;
        emit log_named_uint("one day stale: due() in bips of saleSupply", share);
        assertGt(share, 4_000, "over 40% of the sale is a backlog before anyone has bid");
    }
}
