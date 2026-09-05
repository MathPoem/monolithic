// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../src/GenerousAuction.sol";
import {IGenerousAuction} from "../src/interfaces/IGenerousAuction.sol";
import {Mono} from "../src/Mono.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {TestERC20} from "./TestERC20.sol";
import {MockPool} from "./MockPool.sol";

contract PoCAdminDump is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;
    MockPool internal monoPool;

    address internal seller = address(0xF1);
    address internal adminBidder = address(0xAD);
    address internal honest = address(0xB0);

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
        monoPool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(monoPool));

        IGenerousAuction.Config memory c = IGenerousAuction.Config({
            token: address(mono),
            currency: address(cur),
            admin: seller,
            floorPrice: FLOOR,
            tickSpacing: SPACING,
            decayQ: uint160(Q96 / 2),
            windowTicks: 8,
            startBlock: uint64(block.number),
            endBlock: 0,
            roundBlocks: K,
            emissionPerRound: 150e18,
            minPremiumBips: 1500,
            previousAuction: address(0)
        });
        auction = new GenerousAuction(c);
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    function _bid(address who, uint256 price, uint256 capTokens) internal {
        mono.transfer(who, 1e18);
        uint128 amount = uint128((capTokens * price) / 1e18);
        cur.mint(who, amount);
        vm.startPrank(who);
        mono.approve(address(auction), 1e18);
        auction.stake(1e18);
        cur.approve(address(auction), amount);
        auction.submitBid(price, amount, who, FLOOR);
        vm.stopPrank();
    }

    function test_adminAcceleratesWholeSaleIntoOneRound() public {
        uint256 supply = auction.saleSupply();
        emit log_named_uint("saleSupply", supply);

        // Honest bidder at floor, admin-controlled bidder at top of book with escrow
        // big enough to swallow the whole supply at its price.
        _bid(honest, FLOOR, 100e18);
        _bid(adminBidder, FLOOR + 3 * SPACING, supply);

        // Admin queues the dump: 1-block rounds, whole supply per round.
        vm.prank(seller);
        auction.setRoundParams(1, type(uint128).max);

        // Next boundary of the CURRENT schedule (K blocks), then one 1-block pending round.
        vm.roll(block.number + K + 1);
        assertEq(auction.due(), supply, "entire remaining sale due at once");

        // Sync distributes everything at instantaneous weights.
        auction.sync(64);
        for (uint256 i; i < 20 && auction.settleCursor() != 0; i++) {
            auction.sync(64);
        }

        (, uint256 owedAdmin) = auction.positionOf(adminBidder);
        (, uint256 owedHonest) = auction.positionOf(honest);
        emit log_named_uint("owed adminBidder", owedAdmin);
        emit log_named_uint("owed honest", owedHonest);
        emit log_named_uint("tokensSold", auction.tokensSold());
        emit log_named_uint("due after", auction.due());

        // Admin's position captured the lion's share of the WHOLE sale in one shot.
        assertGt(owedAdmin, supply / 2, "admin position captured most of the sale supply");
    }
}
