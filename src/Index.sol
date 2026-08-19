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
///      Target weights (`stocks[a].allocationBips`) are recorded but read by NOTHING once a
///      reallocation has started: mint and redeem stay pro-rata off live `balanceOf`, which is
///      what keeps the pot `uiMultiplier`-safe. Per D19 the channel's real target is a per-INDEX
///      RAW quantity (`targetPerIndex`), derived from the weight once, at the start — the weight
///      is the declaration of intent, the quantity is the law.
///
///      Adding an asset is the P6j DEFICIT MINT CHANNEL and nothing else. `startReallocation`
///      lists the leg and opens the channel; while it is open, ordinary pro-rata mint is shut and
///      the only way in is `mintDeficit` — a single-asset deposit of the lacking stock, priced
///      bottom-up from the constituent feeds (never a pool quote) less the D20 haircut. When the
///      per-INDEX quantity is met the channel closes itself and normal minting resumes.
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
    ///      amounts, so legs with different decimals and feeds with different decimals compare.
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
    /// @dev Written once at construction and never touched again — there is no setter, because
    ///      clearing `enabled` or lowering `allocationBips` is a composition reduction, which the
    ///      D12 covenant forbids outside the fire escape.
    mapping(address => Stock) public override stocks;

    /// @param assets_ The pot's legs, in order.
    /// @param allocationsBips_ Target weight per leg, same order, summing to 10_000.
    constructor(address[] memory assets_, uint16[] memory allocationsBips_) Ownable(msg.sender) {
        if (assets_.length == 0) revert NoAssets();
        if (assets_.length != allocationsBips_.length) revert LengthMismatch();

        uint256 total;
        for (uint256 i; i < assets_.length; ++i) {
            address asset = assets_[i];
            uint16 bips = allocationsBips_[i];
            if (asset == address(0)) revert InvalidAsset();
            if (stocks[asset].enabled) revert DuplicateAsset();
            if (bips == 0) revert InvalidAllocation();
            // ponytail: genesis legs get no feed. Nothing prices them — add a constructor argument
            // when something does.
            stocks[asset] = Stock({enabled: true, allocationBips: bips, priceFeed: address(0)});
            _assets.push(asset);
            total += bips;
        }
        if (total != BIPS) revert InvalidAllocation();
    }

    /// @inheritdoc IIndex
    function setPriceFeed(address asset, address priceFeed) external override onlyOwner {
        if (!stocks[asset].enabled) revert InvalidAsset();
        if (priceFeed == address(0)) revert InvalidPriceFeed();
        stocks[asset].priceFeed = priceFeed;
        emit PriceFeedSet(asset, priceFeed);
    }

    /// @inheritdoc IIndex
    function startReallocation(address stock, uint16 allocationBips, address priceFeed)
        external
        override
        onlyOwner
    {
        if (reallocating) revert ReallocationActive();
        if (stock == address(0)) revert InvalidAsset();
        if (stocks[stock].enabled) revert DuplicateAsset();
        if (priceFeed == address(0)) revert InvalidPriceFeed();
        // A weight of 10_000 would mean the new leg is the whole pot, which no amount of adding
        // can reach — only selling the rest could, and nothing here sells.
        if (allocationBips == 0 || allocationBips >= BIPS) revert InvalidAllocation();

        uint256 supply = totalSupply();
        if (supply == 0) revert EmptyPot();

        // ponytail: one leg per period. The channel tracks a single deficit, exactly as D19 frames
        // it; list them one after another if a basket ever needs two legs added at once.
        stocks[stock] = Stock({enabled: true, allocationBips: allocationBips, priceFeed: priceFeed});
        _assets.push(stock);

        // The target is a PER-INDEX RAW QUANTITY (D19), fixed here and never recomputed. It is NOT
        // `weight x pot value` — the deposits that fill it also mint shares, so the denominator
        // grows in step with the numerator. Filling to weight `w` purely by adding lands the new
        // leg at `w x (pot value per INDEX, measured right now)`, and that is what gets stored.
        uint256 perIndex = _perIndexValue(supply);
        targetPerIndex = _amount(stock, FixedPointMathLib.fullMulDiv(perIndex, allocationBips, BIPS));
        if (targetPerIndex == 0) revert InvalidAllocation();
        pendingAsset = stock;
        reallocating = true;
        emit ReallocationStarted(stock, allocationBips, priceFeed, targetPerIndex);
    }

    /// @inheritdoc IIndex
    function deficit() public view override returns (uint256) {
        if (!reallocating) return 0;
        uint256 need = FixedPointMathLib.fullMulDiv(targetPerIndex, totalSupply(), VALUE_SCALE);
        uint256 held = potBalance(pendingAsset);
        return held >= need ? 0 : need - held;
    }

    /// @inheritdoc IIndex
    function mintDeficit(uint256 amountIn, address to) external override nonReentrant returns (uint256 shares) {
        if (!reallocating) revert NoReallocation();
        if (amountIn == 0) revert ZeroShares();

        address asset = pendingAsset;
        uint256 perIndex = _perIndexValue(totalSupply());

        // Deficit-only, and sized against the deficit AFTER this deposit's own shares land. Capping
        // at the raw deficit instead would leave the channel asymptotic: every deposit mints supply,
        // which lifts the absolute target, so the naive cap never quite closes it.
        uint256 owed = deficit();
        if (owed == 0) revert NoDeficit();
        uint256 dilution = FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(_value(asset, targetPerIndex), BIPS - HAIRCUT_BIPS, BIPS),
            VALUE_SCALE,
            perIndex
        );
        // `dilution < VALUE_SCALE` because the target was struck at a weight below 100% against a
        // per-INDEX value that only grows as the channel fills. Belt and braces all the same.
        if (dilution >= VALUE_SCALE) revert InvalidAllocation();
        uint256 maxIn = FixedPointMathLib.fullMulDivUp(owed, VALUE_SCALE, VALUE_SCALE - dilution);
        if (amountIn > maxIn) amountIn = maxIn;

        // Bottom-up: the deposit is priced by its own feed, the pot by all of its feeds. No INDEX
        // trading venue is consulted anywhere, by design (D18).
        uint256 paidValue = FixedPointMathLib.fullMulDiv(_value(asset, amountIn), BIPS - HAIRCUT_BIPS, BIPS);
        shares = FixedPointMathLib.fullMulDiv(paidValue, VALUE_SCALE, perIndex);
        if (shares == 0) revert ZeroShares();

        asset.safeTransferFrom(msg.sender, address(this), amountIn);
        _mint(to, shares);
        emit DeficitMinted(msg.sender, to, amountIn, shares);

        if (deficit() == 0) {
            reallocating = false;
            emit ReallocationCompleted(asset, potBalance(asset));
        }
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

    /// @notice Raw balance of one leg currently in the pot.
    function potBalance(address asset) public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice What minting `shares` costs, per leg. Rounds up — the pot never loses.
    function costToMint(uint256 shares) public view override returns (uint256[] memory amounts) {
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
    function proceedsOfRedeem(uint256 shares) public view override returns (uint256[] memory amounts) {
        uint256 supply = totalSupply();
        amounts = new uint256[](_assets.length);
        if (supply == 0) return amounts;
        for (uint256 i; i < _assets.length; ++i) {
            amounts[i] = FixedPointMathLib.fullMulDiv(potBalance(_assets[i]), shares, supply);
        }
    }

    /// @notice Wrap stocks into INDEX, in kind, at the current pot slice.
    /// @param shares INDEX to receive. The caller pays each leg pro-rata.
    function mint(uint256 shares, address to) external override nonReentrant returns (uint256[] memory paid) {
        // Shut while the channel is open: a pro-rata mint would charge nothing for the leg being
        // filled, so it would grow supply without growing the new leg and push the target away.
        if (reallocating) revert ReallocationActive();
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
    function redeem(uint256 shares, address to) external override nonReentrant returns (uint256[] memory got) {
        if (shares == 0) revert ZeroShares();
        got = proceedsOfRedeem(shares);
        // Burn before paying out: the slice was measured against the pre-burn supply.
        _burn(msg.sender, shares);
        for (uint256 i; i < _assets.length; ++i) {
            if (got[i] > 0) _assets[i].safeTransfer(to, got[i]);
        }
        emit Unwrapped(msg.sender, to, shares);
    }

    // -------------------------------------------------------------- VALUATION

    /// @dev The pot's whole value, in 1e18 USD. Every leg must have a live feed.
    function _potValue() internal view returns (uint256 total) {
        for (uint256 i; i < _assets.length; ++i) {
            total += _value(_assets[i], potBalance(_assets[i]));
        }
    }

    /// @dev Pot value backing one INDEX (1e18 shares), in 1e18 USD.
    function _perIndexValue(uint256 supply) internal view returns (uint256 perIndex) {
        perIndex = FixedPointMathLib.fullMulDiv(_potValue(), VALUE_SCALE, supply);
        if (perIndex == 0) revert EmptyPot();
    }

    /// @dev The leg's live price, guarded: a feed must exist, answer positive, and be fresh.
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

    /// @dev The inverse: `value` 1e18 USD, in raw units of `asset`.
    function _amount(address asset, uint256 value) internal view returns (uint256) {
        if (value == 0) return 0;
        (uint256 price, uint256 unit) = _price(asset);
        uint256 usd = FixedPointMathLib.fullMulDiv(value, 10 ** IERC20Metadata(asset).decimals(), VALUE_SCALE);
        return FixedPointMathLib.fullMulDiv(usd, unit, price);
    }
}
