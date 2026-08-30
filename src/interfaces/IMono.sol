// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIndex} from "./IIndex.sol";

/// @title IMono
/// @notice Public surface of the MONO reserve token and its INDEX vault (HANDBOOK §3.1–3.2).
///         ERC-20 functions come from the token base; everything vault-side is here.
interface IMono {
    event Minted(address indexed to, uint256 shares, uint256 assetsIn);
    event Burned(address indexed from, uint256 shares);
    /// @notice The MONO/INDEX pool was named. Fires exactly once in the contract's life.
    event PoolSet(address indexed pool);

    error InvalidParams();
    error NoSupply();
    error ZeroShares();
    error AboveGenesisCap();
    error Dilutive();
    error PoolAlreadySet();
    error PoolNotSet();
    error InvalidPool();
    error InvalidPrice();

    /// @notice The INDEX this vault holds. The only thing that ever backs MONO.
    function index() external view returns (IIndex);
    function genesisCap() external view returns (uint256);
    function genesisDone() external view returns (bool);

    function totalIndex() external view returns (uint256);
    function nav() external view returns (uint256);

    /// @notice The MONO/INDEX Uniswap v3 pool the market price is read from. Zero until `setPool`.
    function pool() external view returns (address);

    /// @dev Owner-only, and callable exactly once — the pool cannot exist before this token does,
    ///      so it cannot be a constructor immutable, but it is immutable in every other sense.
    ///      Reverts `InvalidPool` unless the pool holds exactly MONO and INDEX.
    function setPool(address pool_) external;

    /// @notice The pool's MONO price, in INDEX per MONO, 18 decimals. Same unit as `nav()`.
    function poolPrice() external view returns (uint256);

    /// @notice `poolPrice() - nav()`. Positive: MONO trades above book. Negative: below, which is
    ///         where the wall bids. In INDEX per MONO, 18 decimals.
    function premium() external view returns (int256);

    /// @notice The most MONO `mint` will accept `indexAmount` INDEX for — the inverse of its
    ///         non-dilution check, rounded down.
    function maxIssuable(uint256 indexAmount) external view returns (uint256);

    /// @dev Owner-only. First call seeds the vault (capped) and sets opening NAV;
    ///      every later call is non-dilutive.
    function mint(uint256 shares, uint256 assetsIn, address to) external;
    function burn(uint256 shares) external;
}
