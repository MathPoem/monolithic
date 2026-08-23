// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IIndex} from "./interfaces/IIndex.sol";

/// @title Index
/// @notice The basket wrapper (HANDBOOK §5). One pot of tokenized stocks, one fungible
///         claim on it. Public, symmetric, in-kind mint and burn at the current pot
///         slice — mint and burn always open, so INDEX is never a trap state.
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
///      Target weights (`stocks[a].allocationBips`) are recorded but read by NOTHING once a
///      reallocation has started: mint and burn stay pro-rata off live `balanceOf`, which is
///      what keeps the pot `uiMultiplier`-safe. Per D19 the channel's real target is a per-INDEX
///      RAW quantity (`targetPerIndex`), derived from the weight once, at the start — the weight
///      is the declaration of intent, the quantity is the law.
///
///      Adding an asset is the P6j DEFICIT MINT CHANNEL and nothing else. `addStock`
///      lists the stock and opens the channel; while it is open `mint` charges for that stock ALONE —
///      a single-asset deposit of the lacking stock, priced bottom-up from the constituent feeds
///      (never a pool quote) less the D20 haircut. Minting is never shut, only repriced: ask
///      `calculateAmountOfAssetsToMintIndex` what a mint costs and it answers for whichever regime is in force. When the
///      per-INDEX quantity is met the channel closes itself and the pro-rata slice comes back.
///
///      NEVER REDUCE (D12) holds the strongest way available: no function that removes an asset
///      or lowers a per-INDEX quantity exists in the bytecode at all. Nothing here sells. Redeem
///      is never gated, in the channel or out of it — redemption is pro-rata, so it is
///      ratio-neutral and cannot undo the channel's progress.
///
///      NOT built here, deliberately: the P7 wrapper fee (still `[PENDING]`), the channel's
///      metering and market-hours gate, the LITH vote that is supposed to authorise a listing
///      (`onlyOwner` stands in), and the fire escape.
contract Index is IIndex, ERC20, Ownable, ReentrancyGuardTransient {
    using SafeTransferLib for address;

    /// @dev Shares locked forever on the first mint, so the pot can never be emptied back
    ///      to a zero-supply state and re-seeded at a manipulated slice.
    uint256 internal constant MIN_LIQUIDITY = 1e3;
    /// @dev Floors the first mint well above MIN_LIQUIDITY so the locked dust is noise.
    uint256 internal constant MIN_FIRST_MINT = 1e18;
    /// @dev Basis-point denominator. Target weights must sum to exactly this.
    uint256 internal constant BIPS = 10_000;
    /// @dev A feed older than this is treated as no price at all.
    ///      ponytail: one age for every feed. Per-feed heartbeats if a slow feed ever gets listed.
    uint256 internal constant MAX_FEED_AGE = 1 hours;
    /// @dev Everything is valued in this many decimals of USD before being converted back to token
    ///      amounts, so stocks with different decimals and feeds with different decimals compare.
    uint256 internal constant VALUE_SCALE = 1e18;
    /// @dev D20 haircut on a deficit deposit. Wider than the worst relative feed error, so the
    ///      oracle cannot dilute holders — a mispricing costs the minter, never the pot.
    uint256 internal constant HAIRCUT_BIPS = 100;

    address[] internal _assets;

    /// @inheritdoc IIndex
    bool public override reallocating;

    /// @inheritdoc IIndex
    address public override pendingAsset;

    /// @inheritdoc IIndex
    uint256 public override targetPerIndex;

    /// @inheritdoc IIndex
    /// @dev Written once at construction and never deleted — there is no path that clears a stock,
    ///      because that is a composition reduction, which the D12 covenant forbids outside the
    ///      fire escape.
    mapping(address => Stock) public override stocks;

    /// @param stocks_ The pot's stocks, in order. Every entry must have a non-zero asset, non-zero
    ///        allocation, and non-zero feed; allocations must sum to 10_000.
    constructor(Stock[] memory stocks_) Ownable(msg.sender) {
        if (stocks_.length == 0) revert NoAssets();

        uint256 total;
        for (uint256 i; i < stocks_.length; ++i) {
            Stock memory stock = stocks_[i];
            if (stock.asset == address(0)) revert InvalidAsset();
            if (stock.priceFeed == address(0)) revert InvalidPriceFeed();
            if (stocks[stock.asset].asset != address(0)) revert DuplicateAsset();
            if (stock.allocationBips == 0) revert InvalidAllocation();
            for (uint256 j; j < i; ++j) {
                if (stocks_[j].asset == stock.asset) revert DuplicateAsset();
            }

            stocks[stock.asset] = stock;
            _assets.push(stock.asset);

            emit PriceFeedSet(stock.asset, stock.priceFeed);
            total += stock.allocationBips;
        }
        if (total != BIPS) revert InvalidAllocation();
    }

    /// @inheritdoc IIndex
    function setPriceFeed(address asset, address priceFeed) external override onlyOwner {
        if (stocks[asset].asset == address(0)) revert InvalidAsset();
        if (priceFeed == address(0)) revert InvalidPriceFeed();
        stocks[asset].priceFeed = priceFeed;
        emit PriceFeedSet(asset, priceFeed);
    }

    /// @inheritdoc IIndex
    function addStock(Stock calldata stock) external override onlyOwner {
        if (reallocating) revert ReallocationActive();
        if (stock.asset == address(0)) revert InvalidAsset();
        if (stock.priceFeed == address(0)) revert InvalidPriceFeed();
        if (stocks[stock.asset].asset != address(0)) revert DuplicateAsset();
        if (stock.allocationBips == 0 || stock.allocationBips >= BIPS) revert InvalidAllocation();

        uint256 supply = totalSupply();
        if (supply == 0) revert EmptyPot();

        uint256 remaining = BIPS - stock.allocationBips;
        uint256 scaledTotal;
        for (uint256 i; i < _assets.length; ++i) {
            address asset = _assets[i];
            stocks[asset].allocationBips = uint16(
                FixedPointMathLib.fullMulDiv(stocks[asset].allocationBips, remaining, BIPS)
            );
            scaledTotal += stocks[asset].allocationBips;
        }
        // Rounding dust from proportional rescale lands on the first incumbent.
        if (scaledTotal + stock.allocationBips != BIPS) {
            stocks[_assets[0]].allocationBips += uint16(BIPS - scaledTotal - stock.allocationBips);
        }

        stocks[stock.asset] = stock;
        _assets.push(stock.asset);
        emit PriceFeedSet(stock.asset, stock.priceFeed);

        // The target is a PER-INDEX RAW QUANTITY (D19), fixed here and never recomputed. It is NOT
        // `weight x pot value` — the deposits that fill it also mint shares, so the denominator
        // grows in step with the numerator. Filling to weight `w` purely by adding lands the new
        // stock at `w x (pot value per INDEX, measured right now)`, and that is what gets stored.
        uint256 perIndex = _perIndexValue(supply);
        targetPerIndex =
            _amount(stock.asset, FixedPointMathLib.fullMulDiv(perIndex, stock.allocationBips, BIPS), false);
        if (targetPerIndex == 0) revert InvalidAllocation();
        pendingAsset = stock.asset;
        reallocating = true;
        emit StockAdded(stock.asset, stock.allocationBips, stock.priceFeed, targetPerIndex);
    }

    /// @inheritdoc IIndex
    function deficit() public view override returns (uint256) {
        if (!reallocating) return 0;
        uint256 need = FixedPointMathLib.fullMulDiv(targetPerIndex, totalSupply(), VALUE_SCALE);
        uint256 held = indexAssetBalance(pendingAsset);
        return held >= need ? 0 : need - held;
    }

    /// @inheritdoc IIndex
    function maxDeficitMint() public view override returns (uint256) {
        uint256 owed = deficit();
        if (owed == 0) return 0;
        uint256 perIndex = _perIndexValue(totalSupply());
        // The deposit that lands exactly on target is MORE than the raw deficit: it mints shares,
        // and those shares lift the absolute target too. Solve for the fixed point rather than
        // capping at `deficit()`, which would leave the channel asymptotic and never close it.
        uint256 dilution = FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(_value(pendingAsset, targetPerIndex), BIPS - HAIRCUT_BIPS, BIPS),
            VALUE_SCALE,
            perIndex
        );
        if (dilution >= VALUE_SCALE) return 0;
        uint256 maxIn = FixedPointMathLib.fullMulDivUp(owed, VALUE_SCALE, VALUE_SCALE - dilution);
        uint256 value = FixedPointMathLib.fullMulDiv(_value(pendingAsset, maxIn), BIPS - HAIRCUT_BIPS, BIPS);
        return FixedPointMathLib.fullMulDiv(value, VALUE_SCALE, perIndex);
    }

    function name() public pure override returns (string memory) {
        return "Monolithic Index";
    }

    function symbol() public pure override returns (string memory) {
        return "INDEX";
    }

    function assets() external view override returns (address[] memory) {
        return _assets;
    }

    function assetCount() external view override returns (uint256) {
        return _assets.length;
    }

    /// @notice INDEX's asset balance
    function indexAssetBalance(address asset) public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice calculates amount of underlying assets necessary to mint one index
    function calculateAmountOfAssetsToMintIndex(uint256 shares) public view override returns (uint256[] memory amounts) {
        uint256 supply = totalSupply();
        amounts = new uint256[](_assets.length);

        if (reallocating) {
            uint256 value = FixedPointMathLib.fullMulDivUp(
                FixedPointMathLib.fullMulDivUp(shares, _perIndexValue(supply), VALUE_SCALE), BIPS, BIPS - HAIRCUT_BIPS
            );
            amounts[_indexOf(pendingAsset)] = _amount(pendingAsset, value, true);
            return amounts;
        }

        for (uint256 i; i < _assets.length; ++i) {
            // Empty pot: genesis parity, one raw unit per share of every stock.
            amounts[i] = supply == 0
                ? shares
                : FixedPointMathLib.fullMulDivUp(indexAssetBalance(_assets[i]), shares, supply);
        }
    }

    /// @notice What redeeming `shares` returns, per stock. Rounds down — the pot never loses.
    function proceedsOfRedeem(uint256 shares) public view override returns (uint256[] memory amounts) {
        uint256 supply = totalSupply();
        amounts = new uint256[](_assets.length);
        if (supply == 0) return amounts;
        for (uint256 i; i < _assets.length; ++i) {
            amounts[i] = FixedPointMathLib.fullMulDiv(indexAssetBalance(_assets[i]), shares, supply);
        }
    }

    /// @notice Mints INDEX to to address, if the reallocation mode is enabled then mint will accept only the token which is being added
    /// @param shares INDEX to receive. The caller pays whatever `calculateAmountOfAssetsToMintIndex` says.
    function mint(uint256 shares, address to) external override nonReentrant returns (uint256[] memory paid) {
        if (shares == 0) revert ZeroShares();
        // Deficit-only: the channel never takes more than closes it.
        if (reallocating && shares > maxDeficitMint()) revert ExceedsDeficit();
        uint256 supply = totalSupply();
        if (supply == 0 && shares < MIN_FIRST_MINT) revert FirstMintTooSmall();

        paid = calculateAmountOfAssetsToMintIndex(shares);
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

        // The deposit that meets the per-INDEX target closes the channel and hands minting back to
        // the pro-rata path. A shortfall below one raw unit per INDEX is rounding, not a deficit.
        if (reallocating && FixedPointMathLib.fullMulDiv(deficit(), VALUE_SCALE, totalSupply()) == 0) {
            reallocating = false;
            emit ReallocationCompleted(pendingAsset, indexAssetBalance(pendingAsset));
        }
    }

    /// @notice Unwrap INDEX back into its slice of the pot, in kind. Never gated.
    function burn(uint256 shares, address to) external override nonReentrant returns (uint256[] memory got) {
        if (shares == 0) revert ZeroShares();
        got = proceedsOfRedeem(shares);
        // Burn before paying out: the slice was measured against the pre-burn supply.
        _burn(msg.sender, shares);
        for (uint256 i; i < _assets.length; ++i) {
            if (got[i] > 0) _assets[i].safeTransfer(to, got[i]);
        }
        emit Unwrapped(msg.sender, to, shares);
    }

    /// @dev Position of a stock in `_assets`. Reverts if it is not one.
    function _indexOf(address asset) internal view returns (uint256) {
        for (uint256 i; i < _assets.length; ++i) {
            if (_assets[i] == asset) return i;
        }
        revert InvalidAsset();
    }

    // -------------------------------------------------------------- VALUATION

    /// @dev The pot's whole value, in 1e18 USD. Every stock must have a live feed.
    function _potValue() internal view returns (uint256 total) {
        for (uint256 i; i < _assets.length; ++i) {
            total += _value(_assets[i], indexAssetBalance(_assets[i]));
        }
    }

    /// @dev Pot value backing one INDEX (1e18 shares), in 1e18 USD.
    function _perIndexValue(uint256 supply) internal view returns (uint256 perIndex) {
        perIndex = FixedPointMathLib.fullMulDiv(_potValue(), VALUE_SCALE, supply);
        if (perIndex == 0) revert EmptyPot();
    }

    /// @dev The stock's live price, guarded: a feed must exist, answer positive, and be fresh.
    function _price(address asset) internal view returns (uint256 price, uint256 unit) {
        address feed = stocks[asset].priceFeed;
        if (feed == address(0)) revert MissingPriceFeed();
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_FEED_AGE) revert StalePrice();
        price = uint256(answer);
        unit = 10 ** IAggregatorV3(feed).decimals();
    }

    /// @dev `amount` raw units of `asset`, in 1e18 USD.
    function _value(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        (uint256 price, uint256 unit) = _price(asset);
        uint256 usd = FixedPointMathLib.fullMulDiv(amount, price, unit);
        return FixedPointMathLib.fullMulDiv(usd, VALUE_SCALE, 10 ** IERC20Metadata(asset).decimals());
    }

    /// @dev The inverse: `value` 1e18 USD, in raw units of `asset`. `roundUp` is for the stock a
    ///      caller PAYS, so the pot never comes out short of a rounding step.
    function _amount(address asset, uint256 value, bool roundUp) internal view returns (uint256) {
        if (value == 0) return 0;
        (uint256 price, uint256 unit) = _price(asset);
        uint256 decimals = 10 ** IERC20Metadata(asset).decimals();
        if (roundUp) {
            return FixedPointMathLib.fullMulDivUp(
                FixedPointMathLib.fullMulDivUp(value, decimals, VALUE_SCALE), unit, price
            );
        }
        uint256 usd = FixedPointMathLib.fullMulDiv(value, decimals, VALUE_SCALE);
        return FixedPointMathLib.fullMulDiv(usd, unit, price);
    }
}
