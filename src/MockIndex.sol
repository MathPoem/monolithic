// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title MockIndex
/// @notice A faucet ERC20 for local and testnet bring-up: 18 decimals, anyone can mint, name and
///         symbol chosen at deploy. Stands in for INDEX — the `currency` side of a
///         `GenerousAuction` and the asset a `Mono` is backed by. Never the `token` side: that has
///         to be a real `Mono`, because the auction mints through it.
/// @dev Deliberately NOT `Index`. That one is a claim on a pot of stocks and can only be minted by
///      depositing the legs in kind; this one is a plain balance with a faucet, so a testnet bidder
///      can get some without a basket existing. `GenerousAuction` assumes 18 decimals on its
///      currency — the WAD fill math is not decimal-agnostic — which is what this matches.
///
///      ponytail: open `mint`, no owner, no cap. That is the whole point of a faucet token, and the
///      reason it must never be deployed anywhere that matters. Gate it if that ever changes.
contract MockIndex is ERC20 {
    string private _name;
    string private _symbol;

    /// @param initialSupply Minted to the deployer at construction. 0 deploys an empty token.
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) {
        _name = name_;
        _symbol = symbol_;
        if (initialSupply != 0) _mint(msg.sender, initialSupply);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
