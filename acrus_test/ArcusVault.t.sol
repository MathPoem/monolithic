// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {ArcusVault, IERC20} from "./ArcusVault.sol";

/// @notice Proves the vault's hand-built digest is the one Permit2 actually computes, by making
///         real Permit2 on chain 4663 pull the sell leg against it. Nothing here mocks the
///         verification path — a wrong type string fails with `InvalidContractSignature`.
///
/// Run: `FOUNDRY_PROFILE=arcus forge test --match-path acrus_test/ArcusVault.t.sol -vv`
contract ArcusVaultTest is Test {
    ISignatureTransfer internal constant PERMIT2 =
        ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address internal constant SETTLEMENT = 0x006102b16A04c20306A28b652745D3973D7D24fa;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev Exactly what Permit2 appends to its own stub; the vault hardcodes the joined string.
    string internal constant WITNESS_TYPE_STRING =
        "TakerIntent witness)TakerIntent(address taker,address takerSellToken,address takerBuyToken,uint256 sellAmount,uint256 minBuyAmount,bool allowWrapped,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)";
    bytes32 internal constant TAKER_INTENT_TYPEHASH = keccak256(
        "TakerIntent(address taker,address takerSellToken,address takerBuyToken,uint256 sellAmount,uint256 minBuyAmount,bool allowWrapped,uint256 nonce,uint256 deadline)"
    );

    uint256 internal constant SELL_AMOUNT = 111672269330599;
    uint256 internal constant MIN_BUY = 23_000; // ~$0.023 of USDG (6 dec), floor only
    uint256 internal constant NONCE = 42;

    ArcusVault internal vault;
    uint256 internal deadline;

    function setUp() public {
        vm.createSelectFork("chain4663");
        vault = new ArcusVault(address(this), SETTLEMENT);
        deal(NVDA, address(vault), SELL_AMOUNT);
        deadline = block.timestamp + 300;
    }

    function _witness() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                TAKER_INTENT_TYPEHASH,
                address(vault),
                NVDA,
                USDG,
                SELL_AMOUNT,
                MIN_BUY,
                false,
                NONCE,
                deadline
            )
        );
    }

    function _pull(uint256 nonce) internal {
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: NVDA, amount: SELL_AMOUNT}),
            nonce: nonce,
            deadline: deadline
        });
        ISignatureTransfer.SignatureTransferDetails memory details =
            ISignatureTransfer.SignatureTransferDetails({to: SETTLEMENT, requestedAmount: SELL_AMOUNT});

        // The Arcus settlement contract is the spender, so it must be the caller.
        vm.prank(SETTLEMENT);
        PERMIT2.permitWitnessTransferFrom(
            permit, details, address(vault), _witness(), WITNESS_TYPE_STRING, ""
        );
    }

    /// @dev The whole question: does real Permit2 accept the armed digest over an empty signature?
    function test_armedIntentIsPullableByPermit2() public {
        bytes32 digest = vault.arm(NVDA, USDG, SELL_AMOUNT, MIN_BUY, NONCE, deadline);
        assertEq(vault.armed(), digest, "armed digest stored");
        assertEq(vault.isValidSignature(digest, ""), bytes4(0x1626ba7e), "vouches for its own digest");

        _pull(NONCE);

        assertEq(IERC20(NVDA).balanceOf(address(vault)), 0, "sell leg left the vault");
        assertEq(IERC20(NVDA).balanceOf(SETTLEMENT), SELL_AMOUNT, "settlement received it");
    }

    /// @dev Nothing armed — Permit2 must bounce off `isValidSignature`.
    function test_unarmedIntentIsRejected() public {
        vm.expectRevert(bytes4(keccak256("InvalidContractSignature()")));
        _pull(NONCE);
    }

    /// @dev Armed for one nonce, pulled with another: a different digest, so still rejected.
    function test_differentTermsAreRejected() public {
        vault.arm(NVDA, USDG, SELL_AMOUNT, MIN_BUY, NONCE, deadline);
        vm.expectRevert(bytes4(keccak256("InvalidContractSignature()")));
        _pull(NONCE + 1);
    }

    function test_onlyOwnerCanArm() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(ArcusVault.NotOwner.selector);
        vault.arm(NVDA, USDG, SELL_AMOUNT, MIN_BUY, NONCE, deadline);
    }

    function test_zeroFloorRejected() public {
        vm.expectRevert(ArcusVault.NoFloor.selector);
        vault.arm(NVDA, USDG, SELL_AMOUNT, 0, NONCE, deadline);
    }
}
