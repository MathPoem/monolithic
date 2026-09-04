// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Index} from "../src/Index.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {MockPool, MockStable} from "./MockPool.sol";
import {MockFeed} from "./IndexMono.t.sol";

/// @notice FIRE-ESCAPE.md Mode 1, executed from inside the pot: the pot signs an Arcus intent over
///         its own assets and the settlement pulls the clip through Permit2.
///
/// Forked against chain 4663 on purpose. The digest is not checked against a fixture or against a
/// second copy of the same arithmetic — real Permit2 recomputes it and calls back into the pot's
/// `isValidSignature`. A wrong type string fails here with `InvalidContractSignature`.
///
/// Run: `forge test --match-path test/IndexArcusSale.t.sol -vv`
contract IndexArcusSaleTest is Test {
    ISignatureTransfer internal constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address internal constant SETTLEMENT = 0x006102b16A04c20306A28b652745D3973D7D24fa;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    /// @dev What Permit2 appends to its own stub. The pot hardcodes the joined string.
    string internal constant WITNESS_TYPE_STRING =
        "TakerIntent witness)TakerIntent(address taker,address takerSellToken,address takerBuyToken,uint256 sellAmount,uint256 minBuyAmount,bool allowWrapped,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)";
    bytes32 internal constant TAKER_INTENT_TYPEHASH = keccak256(
        "TakerIntent(address taker,address takerSellToken,address takerBuyToken,uint256 sellAmount,uint256 minBuyAmount,bool allowWrapped,uint256 nonce,uint256 deadline)"
    );

    int256 internal constant NVDA_PRICE = 212_60000000; // $212.60, 8 dec
    int256 internal constant AAPL_PRICE = 310_35000000; // $310.35, 8 dec

    uint256 internal constant POT_NVDA = 10e18;
    uint256 internal constant CLIP = 0.25e18; // ~$53
    uint256 internal constant DAILY_CAP = 1e18; // ~$212/day
    uint16 internal constant SLIP_BIPS = 100; // 1%

    Index internal index;
    MockFeed internal nvdaFeed;
    MockFeed internal aaplFeed;
    uint256 internal deadline;
    uint256 internal nonce = 42;

    function setUp() public {
        vm.createSelectFork("chain4663");

        IIndex.Stock[] memory stocks = new IIndex.Stock[](2);
        nvdaFeed = new MockFeed(NVDA_PRICE);
        aaplFeed = new MockFeed(AAPL_PRICE);
        MockStable usdc = new MockStable(6);
        MockPool nvdaPool = new MockPool(NVDA, address(usdc), uint256(NVDA_PRICE) * 1e10);
        MockPool aaplPool = new MockPool(AAPL, address(usdc), uint256(AAPL_PRICE) * 1e10);
        stocks[0] =
            IIndex.Stock({asset: NVDA, allocationBips: 5_000, priceFeed: address(nvdaFeed), pool: address(nvdaPool)});
        stocks[1] =
            IIndex.Stock({asset: AAPL, allocationBips: 5_000, priceFeed: address(aaplFeed), pool: address(aaplPool)});
        index = new Index(stocks);

        deal(NVDA, address(index), POT_NVDA);
        deal(AAPL, address(index), 5e18);
        deadline = block.timestamp + 5 minutes;
    }

    /// @dev Every campaign has to clear the 2-day notice period, so every test opens one this way.
    function _openSale(address sell, address buy, uint256 cap, uint16 slip) internal {
        bytes memory data = abi.encodeCall(IIndex.openSale, (sell, buy, cap, slip));
        index.queue(data);
        vm.warp(block.timestamp + index.TIMELOCK_DELAY());
        index.execute(data);
        _refreshFeeds();
        deadline = block.timestamp + 5 minutes;
    }

    /// @dev The notice period is 2 days and a feed goes stale after an hour, so every warp in this
    ///      suite has to re-stamp the rounds or `armSale` reverts with `StalePrice`.
    function _refreshFeeds() internal {
        nvdaFeed.touch();
        aaplFeed.touch();
    }

    /// @dev The cheapest buy amount the feeds will let the pot sign for `CLIP` of NVDA. Read from
    ///      the contract rather than recomputed here — a second copy of the rounding would only
    ///      test that the copy agrees with itself.
    function _floor() internal view returns (uint256) {
        return index.saleFloor(NVDA, CLIP);
    }

    function _witness(uint256 sellAmount, uint256 minBuyAmount, uint256 nonce_) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                TAKER_INTENT_TYPEHASH, address(index), NVDA, AAPL, sellAmount, minBuyAmount, false, nonce_, deadline
            )
        );
    }

    /// @dev What the Arcus settlement contract does with a signed intent.
    function _pull(uint256 sellAmount, uint256 minBuyAmount, uint256 nonce_) internal {
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: NVDA, amount: sellAmount}),
            nonce: nonce_,
            deadline: deadline
        });
        ISignatureTransfer.SignatureTransferDetails memory details =
            ISignatureTransfer.SignatureTransferDetails({to: SETTLEMENT, requestedAmount: sellAmount});

        vm.prank(SETTLEMENT);
        PERMIT2.permitWitnessTransferFrom(
            permit, details, address(index), _witness(sellAmount, minBuyAmount, nonce_), WITNESS_TYPE_STRING, ""
        );
    }

    /*//////////////////////////////////////////////////////////////
                          the crux: does it settle
    //////////////////////////////////////////////////////////////*/

    /// @dev Real Permit2 recomputes the digest and asks the pot about it over an empty signature.
    function test_armedClipIsPullableByPermit2() public {
        _openSale(NVDA, AAPL, DAILY_CAP, SLIP_BIPS);
        uint256 minBuy = _floor();

        bytes32 digest = index.armSale(NVDA, CLIP, minBuy, nonce, deadline);
        assertEq(index.armedIntent(), digest, "digest armed");
        assertEq(index.isValidSignature(digest, ""), bytes4(0x1626ba7e), "pot vouches for it");
        assertEq(IERC20(NVDA).allowance(address(index), address(PERMIT2)), CLIP, "allowance is the clip");

        _pull(CLIP, minBuy, nonce);

        assertEq(IERC20(NVDA).balanceOf(address(index)), POT_NVDA - CLIP, "sell leg left the pot");
        assertEq(IERC20(NVDA).allowance(address(index), address(PERMIT2)), 0, "allowance fully consumed");

        // The buy leg lands back here in the same settlement transaction. Both tokens are listed,
        // so `_potValue` counts the replacement the instant it arrives and never sees a hole.
        deal(AAPL, address(index), IERC20(AAPL).balanceOf(address(index)) + minBuy);
        assertGt(IERC20(AAPL).balanceOf(address(index)), 5e18, "buy leg is inside the basket");
    }

    function test_unarmedClipIsRejected() public {
        _openSale(NVDA, AAPL, DAILY_CAP, SLIP_BIPS);
        uint256 minBuy = _floor();
        vm.expectRevert(bytes4(keccak256("InvalidContractSignature()")));
        _pull(CLIP, minBuy, nonce);
    }

    /// @dev Armed for one nonce, pulled with another: a different digest, so still refused.
    function test_differentTermsAreRejected() public {
        _openSale(NVDA, AAPL, DAILY_CAP, SLIP_BIPS);
        uint256 minBuy = _floor();
        index.armSale(NVDA, CLIP, minBuy, nonce, deadline);
        vm.expectRevert(bytes4(keccak256("InvalidContractSignature()")));
        _pull(CLIP, minBuy, nonce + 1);
    }

    /*//////////////////////////////////////////////////////////////
                    the keeper is a scheduler, not a seller
    //////////////////////////////////////////////////////////////*/

    /// @dev The single most important guard: the price floor comes from the pot's feeds, so the
    ///      keeper cannot hand the basket to a friendly maker.
    function test_floorRejectsUnderpricedClip() public {
        _openSale(NVDA, AAPL, DAILY_CAP, SLIP_BIPS);
        uint256 belowFloor = _floor() - 1;
        vm.expectRevert(IIndex.PriceFloorTooLow.selector);
        index.armSale(NVDA, CLIP, belowFloor, nonce, deadline);
    }

    function test_dailyCapBoundsTheBlastRadius() public {
        _openSale(NVDA, AAPL, DAILY_CAP, SLIP_BIPS);
        index.armSale(NVDA, DAILY_CAP, index.saleFloor(NVDA, DAILY_CAP), nonce, deadline);

        vm.expectRevert(IIndex.SaleCapExceeded.selector);
        index.armSale(NVDA, 1, 1e18, nonce + 1, deadline);

        // ...and the window rolls.
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        deadline = block.timestamp + 5 minutes;
        index.armSale(NVDA, CLIP, _floor(), nonce + 2, deadline);
    }

    function test_cannotSellMoreThanThePotOwns() public {
        _openSale(NVDA, AAPL, type(uint256).max, SLIP_BIPS);
        uint256 minBuy = index.saleFloor(NVDA, POT_NVDA + 1);
        vm.expectRevert(IIndex.SaleExceedsBalance.selector);
        index.armSale(NVDA, POT_NVDA + 1, minBuy, nonce, deadline);
    }

    function test_intentCannotOutliveItsQuoteForLong() public {
        _openSale(NVDA, AAPL, DAILY_CAP, SLIP_BIPS);
        uint256 minBuy = _floor();
        vm.expectRevert(IIndex.IntentTooLong.selector);
        index.armSale(NVDA, CLIP, minBuy, nonce, block.timestamp + 16 minutes);

        vm.expectRevert(IIndex.IntentExpired.selector);
        index.armSale(NVDA, CLIP, minBuy, nonce, block.timestamp);
    }

    function test_onlyOwnerCanArm() public {
        _openSale(NVDA, AAPL, DAILY_CAP, SLIP_BIPS);
        uint256 minBuy = _floor();
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        index.armSale(NVDA, CLIP, minBuy, nonce, deadline);
    }

    function test_armingNeedsAnOpenCampaign() public {
        vm.expectRevert(IIndex.NoOpenSale.selector);
        index.armSale(NVDA, CLIP, 1e18, nonce, deadline);
    }

    /*//////////////////////////////////////////////////////////////
                          authorising a campaign
    //////////////////////////////////////////////////////////////*/

    function test_openSaleIsTimelocked() public {
        vm.expectRevert(IIndex.NotTimelocked.selector);
        index.openSale(NVDA, AAPL, DAILY_CAP, SLIP_BIPS);
    }

    /// @dev An unlisted buy leg would land outside `_assets`, invisible to `_potValue` — NAV would
    ///      step down at settlement and mint/redeem could be cycled against the gap.
    function test_buyLegMustBeListed() public {
        bytes memory data = abi.encodeCall(IIndex.openSale, (NVDA, address(0xDEAD), DAILY_CAP, SLIP_BIPS));
        index.queue(data);
        vm.warp(block.timestamp + index.TIMELOCK_DELAY());
        vm.expectRevert(IIndex.InvalidAsset.selector);
        index.execute(data);
    }

    function test_slippageCeilingIsHard() public {
        bytes memory data = abi.encodeCall(IIndex.openSale, (NVDA, AAPL, DAILY_CAP, 301));
        index.queue(data);
        vm.warp(block.timestamp + index.TIMELOCK_DELAY());
        vm.expectRevert(IIndex.SlippageTooWide.selector);
        index.execute(data);
    }

    /// @dev Revoking the campaign has to revoke its reach, not just its future.
    function test_closeSaleKillsTheArmedIntent() public {
        _openSale(NVDA, AAPL, DAILY_CAP, SLIP_BIPS);
        index.armSale(NVDA, CLIP, _floor(), nonce, deadline);

        bytes memory data = abi.encodeCall(IIndex.closeSale, (NVDA));
        index.queue(data);
        vm.warp(block.timestamp + index.TIMELOCK_DELAY());
        _refreshFeeds();
        index.execute(data);

        assertEq(index.armedIntent(), bytes32(0), "intent dropped");
        assertEq(IERC20(NVDA).allowance(address(index), address(PERMIT2)), 0, "allowance revoked");
    }

    function test_disarmDropsTheIntent() public {
        _openSale(NVDA, AAPL, DAILY_CAP, SLIP_BIPS);
        index.armSale(NVDA, CLIP, _floor(), nonce, deadline);
        index.disarmSale(NVDA);
        assertEq(index.armedIntent(), bytes32(0), "intent dropped");
        assertEq(IERC20(NVDA).allowance(address(index), address(PERMIT2)), 0, "allowance revoked");
    }
}
