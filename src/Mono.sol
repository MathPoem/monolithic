// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {IMono} from "./interfaces/IMono.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Mono
/// @notice The reserve token and its vault in one contract (HANDBOOK §3.1–3.2). Holds
///         INDEX only; NAV is INDEX-per-MONO and is mechanically non-decreasing.
///
/// @dev **ERC-4626 read surface, not a conformant vault.** Every view is real — `asset`,
///      `totalAssets`, `convertToShares`, `convertToAssets`, the previews — so NAV is one
///      standard call for integrators. Every mutator is closed: `maxDeposit`, `maxMint`,
///      `maxWithdraw` and `maxRedeem` all return 0 and `deposit`/`mint`/`withdraw`/`redeem`
///      revert `Closed()`. Aggregators that index 4626 vaults must read the max functions,
///      which correctly report a vault nobody can enter or exit.
///
///      That is not laziness, it is the design. Open deposit at NAV lets anyone convert
///      backing into MONO at book while MONO trades above book — the premium arbs to zero
///      and the harvest has nothing to sell. Open redeem at par leaves
///      `(A − x·NAV)/(S − x)` unchanged, so the floor stops ratcheting and the vault drains
///      at flat NAV. The floor is the wall (a pool-side bid below NAV whose fills burn),
///      never redemption.
///
///      Issuance is `issue()`, callable only by the harvest module, and it enforces the
///      protocol's central law arithmetically: a mint may never lower NAV. Combined with
///      "no outflow", that makes `nav()` monotonically non-decreasing for the lifetime of
///      the contract — the single invariant the whole thesis rests on.
///
///      ponytail: no wall outflow is built here. The wall is still `[LOCKED direction]`
///      in the handbook (keeper bid vs one-sided range order) and it must buy-and-burn
///      atomically or it is just a drain. It gets its own contract and its own audit;
///      until then this vault has no exit at all, which is the safe default.
contract Mono is IMono, ERC20 {
    using SafeTransferLib for address;

    uint256 internal constant WAD = 1e18;

    /// @notice The backing asset — INDEX. The only thing this vault ever holds.
    address public immutable override asset;
    /// @notice The harvest module: the one address that may mint MONO. Starts as the deployer so
    ///         `genesis` has a caller, then hands off to the harvest contract exactly once.
    address public override issuer;
    /// @dev True once the handoff has happened. There is no second one.
    bool public override issuerHandedOff;
    /// @notice Hard ceiling on the one-shot genesis mint, fixed at deploy.
    uint256 public immutable override genesisCap;

    bool public override genesisDone;

    constructor(address asset_, address issuer_, uint256 genesisCap_) {
        if (asset_ == address(0) || issuer_ == address(0) || genesisCap_ == 0) revert Closed();
        asset = asset_;
        issuer = issuer_;
        genesisCap = genesisCap_;
    }

    function name() public pure override returns (string memory) {
        return "Monolithic";
    }

    function symbol() public pure override returns (string memory) {
        return "MONO";
    }

    // ---------------------------------------------------------------- NAV

    /// @notice INDEX held by the vault. Anything transferred in raises NAV — that is how
    ///         the tax sweep accrues, with no privileged entry point.
    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Backing per MONO, in INDEX, 18 decimals. The floor.
    function nav() public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? WAD : FixedPointMathLib.fullMulDiv(totalAssets(), WAD, supply);
    }

    // ------------------------------------------------- ERC-4626 read surface

    function convertToShares(uint256 assets_) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets_ : FixedPointMathLib.fullMulDiv(assets_, supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : FixedPointMathLib.fullMulDiv(shares, totalAssets(), supply);
    }

    function previewDeposit(uint256 assets_) external view override returns (uint256) {
        return convertToShares(assets_);
    }

    /// @dev Rounds up, per EIP-4626: assets the caller must supply for `shares`.
    function previewMint(uint256 shares) external view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : FixedPointMathLib.fullMulDivUp(shares, totalAssets(), supply);
    }

    /// @dev Rounds up, per EIP-4626: shares burned to release `assets_`.
    function previewWithdraw(uint256 assets_) external view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets_ : FixedPointMathLib.fullMulDivUp(assets_, supply, totalAssets());
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return convertToAssets(shares);
    }

    /// @dev All four are 0: this vault cannot be entered or exited through the 4626 path.
    function maxDeposit(address) external pure override returns (uint256) {
        return 0;
    }

    function maxMint(address) external pure override returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) external pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) external pure override returns (uint256) {
        return 0;
    }

    function deposit(uint256, address) external pure override returns (uint256) {
        revert Closed();
    }

    function mint(uint256, address) external pure override returns (uint256) {
        revert Closed();
    }

    function withdraw(uint256, address, address) external pure override returns (uint256) {
        revert Closed();
    }

    function redeem(uint256, address, address) external pure override returns (uint256) {
        revert Closed();
    }

    // ---------------------------------------------------------- issuance

    /// @notice The one non-harvest mint: seeds the vault and sets the opening NAV.
    /// @dev One shot, capped at deploy, so "supply only ever grows through the issuer"
    ///      stays a checkable invariant with exactly one named exception.
    /// @notice Hand the mint role to the harvest contract. Once.
    /// @dev The auction that mints MONO needs this token's address in its own constructor, so it
    ///      cannot be named in ours. This is the one-shot resolution of that circularity: the
    ///      deployer opens the book with `genesis`, then hands the role over and keeps nothing.
    ///      Gated on `genesisDone` because handing off first would brick `issue` forever.
    function setIssuer(address newIssuer) external override {
        if (msg.sender != issuer) revert NotIssuer();
        if (issuerHandedOff) revert AlreadyHandedOff();
        if (!genesisDone) revert NotGenesis();
        if (newIssuer == address(0)) revert ZeroAddress();
        issuerHandedOff = true;
        emit IssuerSet(issuer, newIssuer);
        issuer = newIssuer;
    }

    function genesis(uint256 shares, uint256 assetsIn, address to) external override {
        if (msg.sender != issuer) revert NotIssuer();
        if (genesisDone) revert AlreadyGenesis();
        if (shares == 0 || assetsIn == 0) revert ZeroShares();
        if (shares > genesisCap) revert AboveGenesisCap();
        genesisDone = true;

        asset.safeTransferFrom(msg.sender, address(this), assetsIn);
        _mint(to, shares);

        emit Genesis(to, shares, assetsIn);
        emit Deposit(msg.sender, to, assetsIn, shares);
    }

    /// @notice Mint MONO against INDEX paid in. The only ongoing issuance path.
    /// @dev Enforces the central law: a mint may never lower NAV. Post-mint NAV is
    ///      `(A + assetsIn)/(S + shares)`, so non-decreasing means `assetsIn·S >= A·shares`
    ///      — checked exactly, with no intermediate rounding through `nav()`.
    function issue(uint256 shares, uint256 assetsIn, address to) external override {
        if (msg.sender != issuer) revert NotIssuer();
        if (!genesisDone) revert NotGenesis();
        if (shares == 0) revert ZeroShares();

        uint256 supply = totalSupply();
        if (supply == 0) revert NoSupply();
        // `assetsIn·S >= A·shares` rearranged so neither product is ever formed — the
        // rounding is up, which can only ask the harvester for more.
        if (assetsIn < FixedPointMathLib.fullMulDivUp(totalAssets(), shares, supply)) revert Dilutive();

        asset.safeTransferFrom(msg.sender, address(this), assetsIn);
        _mint(to, shares);

        emit Issued(to, shares, assetsIn);
        emit Deposit(msg.sender, to, assetsIn, shares);
    }

    /// @notice Burn your own MONO. Retires a claim without touching the pot, so NAV rises.
    ///         This is how wall fills accrete to every remaining holder.
    function burn(uint256 shares) external override {
        _burn(msg.sender, shares);
        emit Burned(msg.sender, shares);
    }
}
