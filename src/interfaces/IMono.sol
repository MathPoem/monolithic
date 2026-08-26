// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIndex} from "./IIndex.sol";

/// @title IMono
/// @notice Public surface of the MONO reserve token and its INDEX vault (HANDBOOK §3.1–3.2).
///         ERC-20 functions come from the token base; everything vault-side is here.
interface IMono {
    event Genesis(address indexed to, uint256 shares, uint256 assetsIn);
    event Minted(address indexed to, uint256 shares, uint256 assetsIn);
    event Burned(address indexed from, uint256 shares);
    /// @dev Borrowed from ERC-4626 so indexers read issuance as a deposit. There is no `Withdraw`
    ///      counterpart, because there is no withdrawal.
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    error InvalidParams();
    error AlreadyGenesis();
    error NotGenesis();
    error NoSupply();
    error ZeroShares();
    error AboveGenesisCap();
    error Dilutive();

    /// @notice The INDEX this vault holds. The only thing that ever backs MONO.
    function index() external view returns (IIndex);
    function genesisCap() external view returns (uint256);
    function genesisDone() external view returns (bool);

    function totalIndex() external view returns (uint256);
    function nav() external view returns (uint256);

    /// @notice The most MONO `mint` will accept `indexAmount` INDEX for — the inverse of its
    ///         non-dilution check, rounded down.
    function maxIssuable(uint256 indexAmount) external view returns (uint256);

    /// @dev Owner-only. Seeds the vault and sets the opening NAV. Once.
    function genesis(uint256 shares, uint256 assetsIn, address to) external;
    /// @dev Owner-only. The only ongoing mint. Non-dilutive.
    function mint(uint256 shares, uint256 assetsIn, address to) external;
    function burn(uint256 shares) external;
}
