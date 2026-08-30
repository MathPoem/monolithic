// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IIndex} from "./interfaces/IIndex.sol";
import {IMono} from "./interfaces/IMono.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract Mono is IMono, ERC20, Ownable {
    using SafeTransferLib for address;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BIPS = 10_000;

    /// @notice INDEX. The only thing this vault ever holds.
    IIndex public immutable override index;
    /// @notice Hard ceiling on the one-shot genesis mint, fixed at deploy.
    uint256 public immutable override genesisCap;

    bool public override genesisDone;
    /// @notice The MONO/INDEX pool. Set once, after deployment, and never again.
    address public override pool;

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

    /// @notice Name the MONO/INDEX pool. One shot: the pool cannot exist before this token does,
    ///         so the constructor cannot take it, but a second call is refused so it is immutable
    ///         from the owner's side too.
    function setPool(address pool_) external override onlyOwner {
        if (pool != address(0)) revert PoolAlreadySet();
        if (pool_ == address(0)) revert InvalidParams();

        // A pool that holds anything else prices something else entirely, and this is the one
        // moment the pairing can be checked — after this the address is frozen.
        address token0 = IUniswapV3Pool(pool_).token0();
        address token1 = IUniswapV3Pool(pool_).token1();
        bool paired = (token0 == address(this) && token1 == address(index))
            || (token1 == address(this) && token0 == address(index));
        if (!paired) revert InvalidPool();

        pool = pool_;
        emit PoolSet(pool_);
    }

    /// @notice What the market pays for MONO, in INDEX per MONO, 18 decimals — `nav()`'s unit.
    /// @dev ponytail: `slot0` is SPOT, so it is movable inside a single block. Same ceiling as
    ///      `Index._poolPrice`, and the same upgrade: the v4 hook's TWAP accumulator
    ///      (HANDBOOK 3.6). Do not gate anything that moves value on this until it lands.
    function poolPrice() public view override returns (uint256) {
        address pool_ = pool;
        if (pool_ == address(0)) revert PoolNotSet();

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool_).slot0();
        if (sqrtPriceX96 == 0) revert InvalidPrice();

        // The square only fits as a 512-bit intermediate: `sqrtPriceX96` reaches 2**160, so the
        // product reaches 2**320. This is token1 per token0, in Q96.
        uint256 ratioX96 = FixedPointMathLib.fullMulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        if (ratioX96 == 0) revert InvalidPrice();

        // Both MONO and INDEX are 18 decimals (neither overrides solady's default), so the unit
        // scaling `Index._poolPrice` has to do cancels here and WAD is the only factor left.
        uint256 price = IUniswapV3Pool(pool_).token0() == address(this)
            // INDEX per MONO already.
            ? FixedPointMathLib.fullMulDiv(ratioX96, WAD, 1 << 96)
            // MONO per INDEX — invert it.
            : FixedPointMathLib.fullMulDiv(WAD, 1 << 96, ratioX96);
        if (price == 0) revert InvalidPrice();
        return price;
    }

    /// @notice How far the market sits above the floor, in INDEX per MONO, 18 decimals.
    /// @dev Signed on purpose. A discount is not an error state — it is the condition the wall
    ///      exists to buy into — so flooring it at zero would throw away the only half that is
    ///      actionable.
    function premium() external view override returns (int256) {
        return SafeCastLib.toInt256(poolPrice()) - SafeCastLib.toInt256(nav());
    }

    /// @notice `premium()` relative to the floor, in basis points — the scale-free form.
    /// @dev A threshold belongs against this, not `premium()`: an absolute gap of 0.15 INDEX means
    ///      15% at a floor of 1.0 and 1.5% at a floor of 10, and the floor only ever ratchets up.
    function premiumBips() external view override returns (int256) {
        uint256 floor = nav();
        // Unreachable while the vault holds anything — there is no outflow — but a zero floor
        // would make the ratio meaningless rather than merely large.
        if (floor == 0) revert InvalidPrice();
        return SafeCastLib.toInt256(FixedPointMathLib.fullMulDiv(poolPrice(), BIPS, floor))
            - SafeCastLib.toInt256(BIPS);
    }

    /// @notice how much mono we can mint for the given amount of index
    function maxIssuable(uint256 indexAmount) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? indexAmount : FixedPointMathLib.fullMulDiv(indexAmount, supply, totalIndex());
    }
}
