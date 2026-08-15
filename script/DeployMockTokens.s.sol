// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {MockIndex} from "../src/MockIndex.sol";

/// @notice Deploys the two faucet ERC20s a `GenerousAuction` needs: MockMONO, the token being sold,
///         and MockIndex, the currency bids are escrowed in. Both are the same `MockIndex` contract
///         with different name/symbol — one deploy each.
/// @dev Signer and network come from `.env` (forge loads it automatically): `WALLET_PRIVATE_KEY`,
///      `WALLET_ADDRESS`, and `RPC_URL_46630` behind the `chain46630` alias in `foundry.toml`. Run:
///
///          forge script script/DeployMockTokens.s.sol --rpc-url chain46630 --broadcast
///
///      Then paste MockMONO into `TOKEN` and MockIndex into `CURRENCY` in
///      `DeployGenerousAuction.s.sol`.
///
///      The key is read inside the script rather than passed as `--private-key`, so it stays out of
///      the command line and the shell history.
///
///      Both mint their whole supply to the deployer at construction, and `mint` stays open to
///      everyone afterwards — so never point this at a real network.
contract DeployMockTokens is Script {
    // ---------------------------------------------------------------- fill these in

    string internal constant MONO_NAME = "MockMONO";
    string internal constant MONO_SYMBOL = "MONO";

    string internal constant INDEX_NAME = "MockIndex";
    string internal constant INDEX_SYMBOL = "INDEX";

    /// @dev Minted to the deployer in each constructor, 18 decimals. 0 deploys an empty token.
    uint256 internal constant INITIAL_SUPPLY = 1_000_000e18;

    // ---------------------------------------------------------------- run

    function run() external returns (MockIndex mono, MockIndex index) {
        vm.startBroadcast(vm.envUint("WALLET_PRIVATE_KEY"));

        mono = new MockIndex(MONO_NAME, MONO_SYMBOL, INITIAL_SUPPLY);
        index = new MockIndex(INDEX_NAME, INDEX_SYMBOL, INITIAL_SUPPLY);

        vm.stopBroadcast();

        console.log("MockMONO  (TOKEN)    :", address(mono));
        console.log("MockIndex (CURRENCY) :", address(index));
        console.log("supply each          :", INITIAL_SUPPLY);
        console.log("holder               :", vm.envAddress("WALLET_ADDRESS"));
        console.log("");
        console.log("Paste these into TOKEN / CURRENCY in DeployGenerousAuction.s.sol.");
    }
}
