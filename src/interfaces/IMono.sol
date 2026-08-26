// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIndex} from "./IIndex.sol";

/// @title IMono
/// @notice Public surface of the MONO reserve token and its INDEX vault (HANDBOOK §3.1–3.2).
///         ERC-20 functions come from the token base; everything vault-side is here.
interface IMono {
    event Minted(address indexed to, uint256 shares, uint256 assetsIn);
    event Burned(address indexed from, uint256 shares);

    error InvalidParams();
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

    /// @dev Owner-only. First call seeds the vault (capped) and sets opening NAV;
    ///      every later call is non-dilutive.
    function mint(uint256 shares, uint256 assetsIn, address to) external;
    function burn(uint256 shares) external;
}
