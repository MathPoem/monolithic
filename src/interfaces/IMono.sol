// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IMono
/// @notice Public surface of the MONO reserve token and its INDEX vault (HANDBOOK §3.1–3.2).
///         ERC-20 functions come from the token base; everything vault-side is here.
interface IMono {
    event Genesis(address indexed to, uint256 shares, uint256 assetsIn);
    event Issued(address indexed to, uint256 shares, uint256 assetsIn);
    event Burned(address indexed from, uint256 shares);
    event IssuerSet(address indexed from, address indexed to);
    // ERC-4626 events, emitted so indexers see issuance as a deposit.
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    error Closed();
    error NotIssuer();
    error AlreadyGenesis();
    error NotGenesis();
    error NoSupply();
    error ZeroShares();
    error AboveGenesisCap();
    error Dilutive();
    error ZeroAddress();
    error AlreadyHandedOff();

    function asset() external view returns (address);
    function issuer() external view returns (address);
    function genesisCap() external view returns (uint256);
    function genesisDone() external view returns (bool);
    function issuerHandedOff() external view returns (bool);

    function totalAssets() external view returns (uint256);
    function nav() external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);

    function maxDeposit(address) external view returns (uint256);
    function maxMint(address) external view returns (uint256);
    function maxWithdraw(address) external view returns (uint256);
    function maxRedeem(address) external view returns (uint256);

    /// @dev All four revert `Closed()`. The vault has no 4626 entry or exit.
    function deposit(uint256 assets, address to) external returns (uint256);
    function mint(uint256 shares, address to) external returns (uint256);
    function withdraw(uint256 assets, address to, address owner) external returns (uint256);
    function redeem(uint256 shares, address to, address owner) external returns (uint256);

    function genesis(uint256 shares, uint256 assetsIn, address to) external;
    function issue(uint256 shares, uint256 assetsIn, address to) external;
    function burn(uint256 shares) external;

    /// @dev One-shot handoff of the mint role, post-genesis. See `Mono.setIssuer`.
    function setIssuer(address newIssuer) external;
}
