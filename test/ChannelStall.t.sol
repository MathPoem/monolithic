// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Index} from "../src/Index.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {TestERC20} from "./TestERC20.sol";

/// Can the deficit channel end up open, non-empty, and unmintable — i.e. stalled forever?
contract ChannelStallTest is Test {
    address internal alice = address(0xA1);

    function _build(uint256 supply, int256 newPx, uint16 bips)
        internal
        returns (Index index, TestERC20 aapl, TestERC20 nvda)
    {
        aapl = new TestERC20("Apple", "AAPLx");
        nvda = new TestERC20("Nvidia", "NVDAx");
        MockFeed af = new MockFeed(200e8);
        MockFeed nf = new MockFeed(newPx);

        IIndex.Stock[] memory g = new IIndex.Stock[](1);
        g[0] = IIndex.Stock({asset: address(aapl), allocationBips: 10_000, priceFeed: address(af)});
        index = new Index(g);

        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(supply);
        aapl.mint(alice, cost[0]);
        vm.startPrank(alice);
        aapl.approve(address(index), type(uint256).max);
        index.mint(supply, alice);
        vm.stopPrank();

        bytes memory add = abi.encodeCall(IIndex.addStock, (IIndex.Stock(address(nvda), bips, address(nf))));
        index.queue(add);
        vm.warp(block.timestamp + index.TIMELOCK_DELAY());
        index.execute(add);
    }

    function _drain(Index index, TestERC20 nvda) internal {
        for (uint256 i; i < 40; ++i) {
            uint256 s = index.deficitToMint();
            if (s == 0) return;
            uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(s);
            nvda.mint(alice, cost[1]);
            vm.startPrank(alice);
            nvda.approve(address(index), type(uint256).max);
            index.mint(s, alice);
            vm.stopPrank();
        }
    }

    /// The stall is permanent: no mint can ever succeed again, so the flag that gates minting
    /// can never be cleared — the branch that clears it lives inside `mint`.
    function test_stallIsUnrecoverable() public {
        (Index index,, TestERC20 nvda) = _build(1e18, 1e8, 100);
        _drain(index, nvda);

        emit log_named_string("reallocating", index.reallocating() ? "true" : "false");
        emit log_named_uint("deficit", index.deficit());
        emit log_named_uint("deficitToMint", index.deficitToMint());
        emit log_named_uint("supply", index.totalSupply());
        assertTrue(index.reallocating(), "channel still open");
        assertGt(index.deficit(), 0, "and still owed something");
        assertEq(index.deficitToMint(), 0, "but nothing is mintable");

        // Every mint is dead: shares >= 1 always exceeds a zero allowance, and shares == 0
        // reverts earlier.
        vm.startPrank(alice);
        vm.expectRevert(IIndex.ExceedsDeficit.selector);
        index.mint(1, alice);
        vm.stopPrank();

        // Donating the shortfall outright zeroes the deficit but does NOT reopen minting:
        // `reallocating` is only ever cleared at the end of a successful mint.
        nvda.mint(address(index), 1e24);
        assertEq(index.deficit(), 0, "shortfall donated away");
        assertEq(index.deficitToMint(), 0, "still zero: owed == 0 returns early");

        vm.startPrank(alice);
        vm.expectRevert(IIndex.ExceedsDeficit.selector);
        index.mint(1e18, alice);
        vm.stopPrank();

        assertTrue(index.reallocating(), "STALLED FOREVER: mint and addStock are both dead");
    }
}

contract MockFeed {
    int256 internal answer_;
    constructor(int256 a) { answer_ = a; }
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer_, 0, block.timestamp, 0);
    }

}
