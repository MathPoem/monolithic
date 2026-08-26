// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IIndex} from "./interfaces/IIndex.sol";
import {IMono} from "./interfaces/IMono.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Mono
/// @notice The reserve token and its vault in one contract (HANDBOOK §3.1–3.2). Holds
///         INDEX only; NAV is INDEX-per-MONO and is mechanically non-decreasing.
contract Mono is IMono, ERC20, Ownable {
    using SafeTransferLib for address;

    uint256 internal constant WAD = 1e18;

    /// @notice INDEX. The only thing this vault ever holds.
    IIndex public immutable override index;
    /// @notice Hard ceiling on the one-shot genesis mint, fixed at deploy.
    uint256 public immutable override genesisCap;

    bool public override genesisDone;

    constructor(IIndex index_, uint256 genesisCap_) Ownable(msg.sender) {
        if (address(index_) == address(0) || genesisCap_ == 0) revert InvalidParams();
        index = index_;
        genesisCap = genesisCap_;
    }

    ////////////////////////////
    ///////// ERC20 ////////////
    ////////////////////////////

    function name() public pure override returns (string memory) {
        return "Monolithic";
    }

    function symbol() public pure override returns (string memory) {
        return "MONO";
    }


    function totalIndex() public view override returns (uint256) {
        return address(index).balanceOf(address(this));
    }



    /// @notice Mint MONO against INDEX paid in. The first call seeds the vault and sets the first price
    /// and the later call rely on that price
    function mint(uint256 shares, uint256 assetsIn, address to) external override onlyOwner {
        if (shares == 0 || assetsIn == 0) revert ZeroShares();

        bool first = !genesisDone;
        if (first) {
            if (shares > genesisCap) revert AboveGenesisCap();
            genesisDone = true;
        } else {
            uint256 supply = totalSupply();
            if (supply == 0) revert NoSupply();
            // Rounding is up, which can only ask the harvester for more.
            if (assetsIn < FixedPointMathLib.fullMulDivUp(totalIndex(), shares, supply)) revert Dilutive();
        }

        address(index).safeTransferFrom(msg.sender, address(this), assetsIn);
        _mint(to, shares);

        emit Minted(to, shares, assetsIn);
    }

    /// @notice Burn your own MONO. Retires a claim without touching the pot, so NAV rises.
    ///         This is how wall fills accrete to every remaining holder.
    function burn(uint256 shares) external override {
        _burn(msg.sender, shares);
        emit Burned(msg.sender, shares);
    }

    /// @notice Backing per MONO, in INDEX, 18 decimals. The floor.
    function nav() public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? WAD : FixedPointMathLib.fullMulDiv(totalIndex(), WAD, supply);
    }

    /// @notice how much mono we can mint for the given amount of index
    function maxIssuable(uint256 indexAmount) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? indexAmount : FixedPointMathLib.fullMulDiv(indexAmount, supply, totalIndex());
    }
}
