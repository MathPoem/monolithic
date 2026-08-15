// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MonoAuction} from "../src/MonoAuction.sol";
import {TestERC20} from "../test/TestERC20.sol";

/// @notice Local anvil bring-up: two tokens, one live auction, a seeded book.
/// @dev Uses anvil's default keys. Never run this against a real network.
contract DeployLocal is Script {
    uint256 internal constant PK_DEPLOYER = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant PK_ALICE = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant PK_BOB = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant PK_CAROL = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant PK_DAVE = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;

    uint128 internal constant SUPPLY = 250e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e17; // 0.1 INDEX ticks
    /// @dev ~5 min of silence at 2s blocks before the auction must be resolved.
    uint64 internal constant IDLE_BLOCKS = 150;

    /// @dev q = 0.5 in Q96. On this coarse grid (one tick = 10% of floor) that puts roughly the
    ///      top seven levels in play, with the top taking ~50% of each round.
    uint256 internal constant DECAY_Q = 1 << 95;
    uint256 internal constant WINDOW_TICKS = 16;

    function run() external {
        address deployer = vm.addr(PK_DEPLOYER);
        address alice = vm.addr(PK_ALICE);
        address bob = vm.addr(PK_BOB);
        address carol = vm.addr(PK_CAROL);

        vm.startBroadcast(PK_DEPLOYER);
        TestERC20 mono = new TestERC20("Monolithic", "MONO");
        // Bids are INDEX-denominated (HANDBOOK §3.5) — a stand-in for the real basket wrapper here.
        TestERC20 index = new TestERC20("Monolithic Index", "INDEX");
        MonoAuction auction = new MonoAuction(address(0), address(0), address(index), SPACING, DECAY_Q, WINDOW_TICKS);

        uint256 id = auction.createMarket(
            address(mono),
            deployer, // fundsRecipient
            deployer, // tokensRecipient
            FLOOR,
            IDLE_BLOCKS
        );
        mono.mint(address(auction), SUPPLY);
        auction.fund(id, SUPPLY);
        auction.openRound(id, uint64(block.number + 500));

        index.mint(alice, 10_000e18);
        index.mint(bob, 10_000e18);
        index.mint(carol, 10_000e18);
        index.mint(vm.addr(PK_DAVE), 10_000e18);
        vm.stopBroadcast();

        // Three bids, one per outcome: alice clears, bob is the marginal tick, carol misses.
        _bid(auction, index, id, PK_ALICE, 4e18, 400e18); // wants 100 of 250 -> fills
        _bid(auction, index, id, PK_BOB, 2e18, 400e18); // wants 200, only 150 left -> partial
        _bid(auction, index, id, PK_CAROL, 12e17, 120e18); // below the clear -> refunded

        _writeDeployment(address(auction), address(mono), address(index), id);

        console.log("MonoAuction :", address(auction));
        console.log("MONO (token):", address(mono));
        console.log("INDEX (curr):", address(index));
        console.log("marketId    :", id);
        console.log("endBlock    :", block.number + 500);
    }

    function _bid(MonoAuction auction, TestERC20 index, uint256 id, uint256 pk, uint256 price, uint128 amount)
        internal
    {
        vm.startBroadcast(pk);
        index.approve(address(auction), amount);
        auction.submitBid(id, price, amount, vm.addr(pk), FLOOR);
        vm.stopBroadcast();
    }

    function _writeDeployment(address auction, address token, address currency, uint256 id) internal {
        string memory json = string.concat(
            '{\n  "auction": "',
            vm.toString(auction),
            '",\n  "token": "',
            vm.toString(token),
            '",\n  "currency": "',
            vm.toString(currency),
            '",\n  "marketId": ',
            vm.toString(id),
            ",\n  \"rpc\": \"http://127.0.0.1:8545\"\n}\n"
        );
        vm.writeFile("web/deployed.json", json);
    }
}
