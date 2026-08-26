// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IIndex} from "./interfaces/IIndex.sol";

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
    /// @dev Fee denominator. NOT basis points: 100_000 is 100%, so 1755 = 1.755% and 50 = 0.05%.
    uint256 internal constant FEE_SCALE = 100_000;
    /// @dev Notice period on every timelocked change. Not settable — a timelock whose length the
    ///      owner can shorten on demand is not a timelock.
    uint256 public constant override TIMELOCK_DELAY = 2 days;
    /// @dev Hard ceiling on `feeRate`, checked on every set. 5%.
    uint256 internal constant MAX_FEE_RATE = 5_000;
    /// @dev D20 haircut on a deficit deposit. Wider than the worst relative feed error, so the
    ///      oracle cannot dilute holders — a mispricing costs the minter, never the pot.
    uint256 internal constant HAIRCUT_BIPS = 100;

    address[] internal _assets;

    bool public override reallocating;
    address public override pendingAsset;
    uint256 public override targetPerIndex;

    mapping(address => Stock) public override stocks;

    /// @dev P7 in-kind fee, per FEE_SCALE. Starts at 0 — nothing is charged until the owner sets it.
    uint256 public override feeRate;
    /// @dev asset => fee collected and not yet withdrawn. Netted out of `_contractAssetBalance`
    ///      exactly like `reserved`, so an uncollected fee is never counted as backing. Without
    ///      that, NAV would rise as fees accrued and fall again when the owner swept them.
    mapping(address => uint256) public override fees;
    /// @dev keccak256(calldata) => when it was queued. Zero means not queued.
    mapping(bytes32 => uint256) public override queuedAt;

    /// @dev owner => asset => raw units a burn booked to `owner` but could not transfer.
    mapping(address => mapping(address => uint256)) public override owed;
    /// @dev asset => sum of every `owed` entry for it. Netted out of the pot's balance by
    ///      `_contractAssetBalance`, so a booked sliver is never counted as pot property again.
    mapping(address => uint256) public override reserved;

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


    /// @dev Reachable only through `execute`, which is the only caller that can be `address(this)`.
    ///      So the owner cannot call these directly — they must queue and wait out TIMELOCK_DELAY.
    modifier timelocked() {
        if (msg.sender != address(this)) revert NotTimelocked();
        _;
    }


    ////////////////////////////
    ///////// ERC20 ////////////
    ////////////////////////////
    function name() public pure override returns (string memory) {
        return "Monolithic Index";
    }

    function symbol() public pure override returns (string memory) {
        return "INDEX";
    }

    /// @notice Mints INDEX to to address, if the reallocation mode is enabled then mint will accept only the token which is being added
    /// @param shares INDEX to receive. The caller pays whatever `calculateAmountOfAssetsToMintIndex` says.
    /// @param to the address to mint the INDEX to
    function mint(uint256 shares, address to) external override nonReentrant returns (uint256[] memory paid) {
        if (shares == 0) revert ZeroShares();
        // Deficit-only: the channel never takes more than closes it.
        if (reallocating && shares > deficitToMint()) revert ExceedsDeficit();
        uint256 supply = totalSupply();
        if (supply == 0 && shares < MIN_FIRST_MINT) revert FirstMintTooSmall();

        uint256[] memory feeAmounts;
        (paid, feeAmounts) = _mintQuote(shares);
        for (uint256 i; i < _assets.length; ++i) {
            if (paid[i] == 0) continue;
            _assets[i].safeTransferFrom(msg.sender, address(this), paid[i]);
            // Booked out of the pot on arrival, so the deposit backs the new shares at exactly the
            // pre-existing ratio and NAV does not move.
            if (feeAmounts[i] > 0) fees[_assets[i]] += feeAmounts[i];
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
            emit ReallocationCompleted(pendingAsset, _contractAssetBalance(pendingAsset));
        }
    }

    /// @notice Unwrap INDEX back into its slice of the pot, in kind. Never gated.
    /// @dev A leg that will not transfer — the issuer froze the token, or blocklisted `to` — is
    ///      booked to `to` and collected later via `claim`, never reverted. One frozen stock out of
    ///      ten must not lock all ten, and the redeemer must not have to forfeit the tenth to get
    ///      the nine. Booked or paid, the leg leaves the pot either way: `reserved` rises by exactly
    ///      what the transfer would have moved, so no other holder's slice shifts.
    function burn(uint256 shares, address to) external override nonReentrant returns (uint256[] memory got) {
        if (shares == 0) revert ZeroShares();
        got = proceedsOfRedeem(shares);
        // Burn before paying out: the slice was measured against the pre-burn supply.
        _burn(msg.sender, shares);
        for (uint256 i; i < _assets.length; ++i) {
            uint256 amount = got[i];
            if (amount == 0) continue;
            address asset = _assets[i];
            if (_tryTransfer(asset, to, amount)) continue;

            owed[to][asset] += amount;
            reserved[asset] += amount;
            got[i] = 0;
            emit LegDeferred(to, asset, amount);
        }
        emit Unwrapped(msg.sender, to, shares);
    }

    /// @inheritdoc IIndex
    function claim(address[] calldata assets_, address to)
        external
        override
        nonReentrant
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](assets_.length);
        for (uint256 i; i < assets_.length; ++i) {
            address asset = assets_[i];
            uint256 amount = owed[msg.sender][asset];
            // Zeroed before the transfer, and a zero balance reverts — so the same asset listed
            // twice in one call cannot pay twice.
            if (amount == 0) revert NothingOwed();
            owed[msg.sender][asset] = 0;
            reserved[asset] -= amount;
            amounts[i] = amount;

            // Deliberately the reverting transfer: a leg that still will not move stays booked.
            asset.safeTransfer(to, amount);
            emit Claimed(msg.sender, asset, to, amount);
        }
    }


    ///////////////////////////////
    ///////// External ////////////
    ///////////////////////////////
    /// @inheritdoc IIndex
    function setPriceFeed(address asset, address priceFeed) external override onlyOwner {
        if (stocks[asset].asset == address(0)) revert InvalidAsset();
        if (priceFeed == address(0)) revert InvalidPriceFeed();
        stocks[asset].priceFeed = priceFeed;
        emit PriceFeedSet(asset, priceFeed);
    }

    /// @inheritdoc IIndex
    function queue(bytes calldata data) external override onlyOwner returns (bytes32 id) {
        id = keccak256(data);
        if (queuedAt[id] != 0) revert AlreadyQueued();
        queuedAt[id] = block.timestamp;
        emit Queued(id, data, block.timestamp + TIMELOCK_DELAY);
    }

    /// @inheritdoc IIndex
    function cancel(bytes calldata data) external override onlyOwner {
        bytes32 id = keccak256(data);
        if (queuedAt[id] == 0) revert NotQueued();
        delete queuedAt[id];
        emit Cancelled(id);
    }

    /// @inheritdoc IIndex
    function execute(bytes calldata data) external override onlyOwner returns (bytes memory result) {
        bytes32 id = keccak256(data);
        uint256 at = queuedAt[id];
        if (at == 0) revert NotQueued();
        if (block.timestamp < at + TIMELOCK_DELAY) revert TimelockPending();
        delete queuedAt[id];

        bool ok;
        (ok, result) = address(this).call(data);
        if (!ok) {
            // Surface the target's own revert, so a change that went stale during the notice
            // period fails with `StalePrice` or `DuplicateAsset` rather than an opaque failure.
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        emit Executed(id);
    }

    /// @inheritdoc IIndex
    function fireEscape(address asset) external override timelocked nonReentrant returns (uint256 amount) {
        if (reallocating) revert ReallocationActive();
        if (stocks[asset].asset == address(0)) revert InvalidAsset();
        // A basket of nothing has no NAV and no way back; `_perIndexValue` would revert forever.
        if (_assets.length == 1) revert LastAsset();

        // The NET balance: claimants' `reserved` legs and uncollected `fees` are not the pot's to
        // give away, and both stay claimable afterwards because they read `owed` / `fees`.
        amount = _contractAssetBalance(asset);

        uint16 freed = stocks[asset].allocationBips;
        uint256 i = _indexOf(asset);
        _assets[i] = _assets[_assets.length - 1];
        _assets.pop();
        delete stocks[asset];
        // Same dust convention as `addStock`: the freed weight lands on the first incumbent.
        stocks[_assets[0]].allocationBips += freed;

        address to = owner();
        if (amount > 0) asset.safeTransfer(to, amount);
        emit FireEscaped(asset, to, amount);
    }

    /// @inheritdoc IIndex
    function setFeeRate(uint256 feeRate_) external override timelocked {
        if (feeRate_ > MAX_FEE_RATE) revert FeeTooHigh();
        feeRate = feeRate_;
        emit FeeRateSet(feeRate_);
    }

    /// @inheritdoc IIndex
    function withdrawFees(address[] calldata assets_, address to)
        external
        override
        onlyOwner
        nonReentrant
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](assets_.length);
        for (uint256 i; i < assets_.length; ++i) {
            address asset = assets_[i];
            // Only ever `fees[asset]`. The pot's own balance and claimants' `reserved` legs are
            // unreachable from here — there is no path in this contract that sweeps either.
            uint256 amount = fees[asset];
            if (amount == 0) revert NothingOwed();
            fees[asset] = 0;
            amounts[i] = amount;
            asset.safeTransfer(to, amount);
            emit FeesWithdrawn(asset, to, amount);
        }
    }

    /// @notice adds one stock to the index, after adding a stock
    /// @notice mint is possible only using the added stock until the ratio is restored
    function addStock(Stock calldata stock) external override timelocked {
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

        // When rounding we end up with small dust left. We add this dust to the first asset to make sure the total allocation is exactly BIPS
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

    /// @notice calculates the deficit of the index in the asset being added
    function deficit() public view override returns (uint256) {
        if (!reallocating) return 0;
        uint256 need = FixedPointMathLib.fullMulDiv(targetPerIndex, totalSupply(), VALUE_SCALE);
        uint256 held = _contractAssetBalance(pendingAsset);
        return held >= need ? 0 : need - held;
    }

    /// @notice calculates the maximum amount of INDEX that can be minted with the asset being added
    function deficitToMint() public view override returns (uint256) {
        uint256 shortfall = deficit();
        if (shortfall == 0) return 0;
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
        uint256 maxIn = FixedPointMathLib.fullMulDivUp(shortfall, VALUE_SCALE, VALUE_SCALE - dilution);
        uint256 value = FixedPointMathLib.fullMulDiv(_value(pendingAsset, maxIn), BIPS - HAIRCUT_BIPS, BIPS);
        return FixedPointMathLib.fullMulDiv(value, VALUE_SCALE, perIndex);
    }

    /// @notice returns the list of assets in the index
    function assets() external view override returns (address[] memory) {
        return _assets;
    }

    /// @notice returns the number of assets in the index
    function assetCount() external view override returns (uint256) {
        return _assets.length;
    }


    /// @notice calculates amount of underlying assets necessary to mint one index
    function calculateAmountOfAssetsToMintIndex(uint256 shares) public view override returns (uint256[] memory amounts) {
        (amounts,) = _mintQuote(shares);
    }

    /// @notice What redeeming `shares` returns, per stock. Rounds down — the pot never loses.
    function proceedsOfRedeem(uint256 shares) public view override returns (uint256[] memory amounts) {
        uint256 supply = totalSupply();
        amounts = new uint256[](_assets.length);
        if (supply == 0) return amounts;
        // No fee on the way out — `feeRate` is charged on mint only. Rounds down: the pot never loses.
        for (uint256 i; i < _assets.length; ++i) {
            amounts[i] = FixedPointMathLib.fullMulDiv(_contractAssetBalance(_assets[i]), shares, supply);
        }
    }



    ///////////////////////////////
    ///////// Internal ////////////
    ///////////////////////////////

    /// @notice What the POT holds of the asset: the raw balance minus the slivers that burns have
    ///         already booked to claimants. Every valuation reads this and never the raw balance —
    ///         a booked sliver belongs to its redeemer, not to the remaining holders, and counting
    ///         it twice would let the next `burn` pay itself out of someone's unclaimed leg.
    /// @dev Floored at zero: a token that claws back or rebases down must not brick every quote.
    function _contractAssetBalance(address asset) internal view returns (uint256) {
        return FixedPointMathLib.zeroFloorSub(
            asset.balanceOf(address(this)), reserved[asset] + fees[asset]
        );
    }

    /// @notice Mint cost per stock, split into the pro-rata base and the fee charged on top.
    /// @dev Two carve-outs, both fee-free: a deficit-channel mint (it pays the 1% D20 haircut
    ///      instead, and keeping it separate leaves `deficitToMint`'s fixed point alone) and the
    ///      genesis wrap (an empty pot has no holders, and taxing the founding deposit just
    ///      charges the founder for seeding the thing).
    function _mintQuote(uint256 shares)
        internal
        view
        returns (uint256[] memory amounts, uint256[] memory feeAmounts)
    {
        uint256 supply = totalSupply();
        amounts = new uint256[](_assets.length);
        feeAmounts = new uint256[](_assets.length);

        if (reallocating) {
            uint256 value = FixedPointMathLib.fullMulDivUp(
                FixedPointMathLib.fullMulDivUp(shares, _perIndexValue(supply), VALUE_SCALE), BIPS, BIPS - HAIRCUT_BIPS
            );
            amounts[_indexOf(pendingAsset)] = _amount(pendingAsset, value, true);
            return (amounts, feeAmounts);
        }

        uint256 rate = supply == 0 ? 0 : feeRate;
        for (uint256 i; i < _assets.length; ++i) {
            // Empty pot: genesis parity, one raw unit per share of every stock.
            uint256 base = supply == 0
                ? shares
                : FixedPointMathLib.fullMulDivUp(_contractAssetBalance(_assets[i]), shares, supply);
            amounts[i] =
                rate == 0 ? base : FixedPointMathLib.fullMulDivUp(base, FEE_SCALE + rate, FEE_SCALE);
            feeAmounts[i] = amounts[i] - base;
        }
    }

    /// @notice `transfer` that reports failure instead of reverting.
    /// @dev solady has `trySafeTransferFrom` but no `trySafeTransfer`; this mirrors its success
    ///      check — the call succeeded, and returned either nothing or a non-zero word.
    ///      ponytail: forwards all gas, so a token that burns 63/64 of it could starve the rest of
    ///      the loop. Stocks are governance-listed, not arbitrary; add a stipend if that changes.
    function _tryTransfer(address asset, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory data) =
            asset.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return success && (data.length == 0 || (data.length == 32 && abi.decode(data, (uint256)) != 0));
    }

    /// @notice Position of a stock in `_assets`. Reverts if it is not one.
    function _indexOf(address asset) internal view returns (uint256) {
        for (uint256 i; i < _assets.length; ++i) {
            if (_assets[i] == asset) return i;
        }
        revert InvalidAsset();
    }

    /// @notice The pot's whole value, in 1e18 USD. Every stock must have a live feed.
    function _potValue() internal view returns (uint256 total) {
        for (uint256 i; i < _assets.length; ++i) {
            total += _value(_assets[i], _contractAssetBalance(_assets[i]));
        }
    }

    /// @notice Pot value backing one INDEX (1e18 shares), in 1e18 USD.
    function _perIndexValue(uint256 supply) internal view returns (uint256 perIndex) {
        perIndex = FixedPointMathLib.fullMulDiv(_potValue(), VALUE_SCALE, supply);
        if (perIndex == 0) revert EmptyPot();
    }

    /// @notice gets price from the price feed
    /// @return price the price of the asset in 1e18 USD
    /// @return unit one unit of the asset with decimals
    function _price(address asset) internal view returns (uint256 price, uint256 unit) {
        address feed = stocks[asset].priceFeed;
        if (feed == address(0)) revert MissingPriceFeed();

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice();

        // TODO: Check how often price feeds are updated and maybe have it per asset or no need to check at all
        // TODO: Check how often price feeds are updated and maybe have it per asset or no need to check at all
        // TODO: Check how often price feeds are updated and maybe have it per asset or no need to check at all
        if (block.timestamp - updatedAt > MAX_FEED_AGE) revert StalePrice();

        price = uint256(answer);
        unit = 10 ** IAggregatorV3(feed).decimals();
    }

    /// @notice Converts raw units of the asset to 1e18 USD
    function _value(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        (uint256 price, uint256 unit) = _price(asset);
        uint256 usd = FixedPointMathLib.fullMulDiv(amount, price, unit);
        return FixedPointMathLib.fullMulDiv(usd, VALUE_SCALE, 10 ** IERC20Metadata(asset).decimals());
    }

    /// @notice inverse of the _vaule function. Converts a usd amount to the raw units of the asset
    /// @param asset the asset to convert to
    /// @param value the value in 1e18 USD
    /// @param roundUp whether to round up the result
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
