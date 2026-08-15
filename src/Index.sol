// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Index
/// @notice The basket wrapper (HANDBOOK §5). One pot of tokenized stocks, one fungible
///         claim on it. Public, symmetric, in-kind mint and redeem at the current pot
///         slice — both legs always open, so INDEX is never a trap state.
///
/// @dev Genesis is 100% AAPLx wrapped 1:1 (D14): with an empty pot, `shares` costs
///      `shares` raw units of every listed asset.
///
///      Everything is pro-rata off **live `balanceOf`**, never a stored recipe. That is
///      what makes the pot `uiMultiplier`-safe for free: a corporate action rescales every
///      holder's claim identically and no code has to know it happened. The one standing
///      assumption is that the stock token applies its multiplier inside `balanceOf`
///      (VERIFICATION item — confirm against Stock.sol before mainnet).
///
///      NOT built here, deliberately: the P7 wrapper fee (still `[PENDING]`), the P6j
///      deficit mint channel, and the fire escape. The composition covenant is enforced
///      the strongest way available — NEVER REDUCE (D12) holds because no function that
///      removes an asset or reduces a per-INDEX quantity exists in the bytecode at all.
///      Adding an asset needs the deficit channel to fill it, so the asset list is fixed
///      at construction until that module ships.
contract Index is ERC20, ReentrancyGuardTransient {
    using SafeTransferLib for address;

    /// @dev Shares locked forever on the first mint, so the pot can never be emptied back
    ///      to a zero-supply state and re-seeded at a manipulated slice.
    uint256 internal constant MIN_LIQUIDITY = 1e3;
    /// @dev Floors the first mint well above MIN_LIQUIDITY so the locked dust is noise.
    uint256 internal constant MIN_FIRST_MINT = 1e18;

    address[] internal _assets;

    event Wrapped(address indexed by, address indexed to, uint256 shares);
    event Unwrapped(address indexed by, address indexed to, uint256 shares);

    error NoAssets();
    error InvalidAsset();
    error DuplicateAsset();
    error ZeroShares();
    error FirstMintTooSmall();

    constructor(address[] memory assets_) {
        if (assets_.length == 0) revert NoAssets();
        for (uint256 i; i < assets_.length; ++i) {
            if (assets_[i] == address(0)) revert InvalidAsset();
            for (uint256 j; j < i; ++j) {
                if (assets_[i] == assets_[j]) revert DuplicateAsset();
            }
            _assets.push(assets_[i]);
        }
    }

    function name() public pure override returns (string memory) {
        return "Monolithic Index";
    }

    function symbol() public pure override returns (string memory) {
        return "INDEX";
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    /// @notice Raw balance of one leg currently in the pot.
    function potBalance(address asset) public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice What minting `shares` costs, per leg. Rounds up — the pot never loses.
    function costToMint(uint256 shares) public view returns (uint256[] memory amounts) {
        uint256 supply = totalSupply();
        amounts = new uint256[](_assets.length);
        for (uint256 i; i < _assets.length; ++i) {
            // Empty pot: genesis parity, one raw unit per share of every leg.
            amounts[i] = supply == 0
                ? shares
                : FixedPointMathLib.fullMulDivUp(potBalance(_assets[i]), shares, supply);
        }
    }

    /// @notice What redeeming `shares` returns, per leg. Rounds down — the pot never loses.
    function proceedsOfRedeem(uint256 shares) public view returns (uint256[] memory amounts) {
        uint256 supply = totalSupply();
        amounts = new uint256[](_assets.length);
        if (supply == 0) return amounts;
        for (uint256 i; i < _assets.length; ++i) {
            amounts[i] = FixedPointMathLib.fullMulDiv(potBalance(_assets[i]), shares, supply);
        }
    }

    /// @notice Wrap stocks into INDEX, in kind, at the current pot slice.
    /// @param shares INDEX to receive. The caller pays each leg pro-rata.
    function mint(uint256 shares, address to) external nonReentrant returns (uint256[] memory paid) {
        if (shares == 0) revert ZeroShares();
        uint256 supply = totalSupply();
        if (supply == 0 && shares < MIN_FIRST_MINT) revert FirstMintTooSmall();

        paid = costToMint(shares);
        for (uint256 i; i < _assets.length; ++i) {
            if (paid[i] > 0) _assets[i].safeTransferFrom(msg.sender, address(this), paid[i]);
        }

        if (supply == 0) {
            // Locked forever: this contract has no path that moves its own INDEX.
            _mint(address(this), MIN_LIQUIDITY);
            _mint(to, shares - MIN_LIQUIDITY);
        } else {
            _mint(to, shares);
        }
        emit Wrapped(msg.sender, to, shares);
    }

    /// @notice Unwrap INDEX back into its slice of the pot, in kind. Never gated.
    function redeem(uint256 shares, address to) external nonReentrant returns (uint256[] memory got) {
        if (shares == 0) revert ZeroShares();
        got = proceedsOfRedeem(shares);
        // Burn before paying out: the slice was measured against the pre-burn supply.
        _burn(msg.sender, shares);
        for (uint256 i; i < _assets.length; ++i) {
            if (got[i] > 0) _assets[i].safeTransfer(to, got[i]);
        }
        emit Unwrapped(msg.sender, to, shares);
    }
}
