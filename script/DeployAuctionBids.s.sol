// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

/// @notice Reads back whatever `block.number` actually is on the chain it is deployed to. On an
///         Arbitrum Orbit rollup that is the SETTLEMENT chain's height, not the rollup's own — the
///         gap this exists to demonstrate.
contract AuctionBids {
    function getBlock() public view returns (uint256) {
        return block.number;
    }
}

/// @dev ponytail: contract and its deploy script in one file. It is a probe, not a subsystem — a
///      second file buys nothing. Run:
///
///          forge script script/DeployAuctionBids.s.sol --rpc-url chain46630 --broadcast
contract DeployAuctionBids is Script {
    function run() external returns (AuctionBids probe) {
        vm.startBroadcast(vm.envUint("WALLET_PRIVATE_KEY"));
        probe = new AuctionBids();
        vm.stopBroadcast();

        console.log("AuctionBids :", address(probe));
    }
}
