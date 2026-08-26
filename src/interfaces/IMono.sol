// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIndex} from "./IIndex.sol";

/// @title IMono
/// @notice Public surface of the MONO reserve token and its INDEX vault (HANDBOOK §3.1–3.2).
///         ERC-20 functions come from the token base; everything vault-side is here.
interface IMono {
    event Genesis(address indexed to, uint256 shares, uint256 assetsIn);
    event Issued(address indexed to, uint256 shares, uint256 assetsIn);
    event Burned(address indexed from, uint256 shares);
    event IssuerSet(address indexed from, address indexed to);
    /// @dev Borrowed from ERC-4626 so indexers read issuance as a deposit. There is no `Withdraw`
    ///      counterpart, because there is no withdrawal.
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    error InvalidParams();
    error NotIssuer();
    error AlreadyGenesis();
    error NotGenesis();
    error NoSupply();
    error ZeroShares();
    error AboveGenesisCap();
    error Dilutive();
    error ZeroAddress();
    error AlreadyHandedOff();

    /// @notice The INDEX this vault holds. The only thing that ever backs MONO.
    function index() external view returns (IIndex);
    /// @notice `address(index)`, under the name integrators expect on a backed token.
    function asset() external view returns (address);
    function issuer() external view returns (address);
    function genesisCap() external view returns (uint256);
    function genesisDone() external view returns (bool);
    function issuerHandedOff() external view returns (bool);

    function totalAssets() external view returns (uint256);
    function nav() external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    function genesis(uint256 shares, uint256 assetsIn, address to) external;
    function issue(uint256 shares, uint256 assetsIn, address to) external;
    function burn(uint256 shares) external;

    /// @dev One-shot handoff of the mint role, post-genesis. See `Mono.setIssuer`.
    function setIssuer(address newIssuer) external;
}
