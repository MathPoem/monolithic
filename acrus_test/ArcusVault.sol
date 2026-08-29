// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IPermit2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title ArcusVault
/// @notice ERC-1271 taker for the Arcus spot RFQ rail — a probe of the "the pot sells its own
///         assets" design before any of it goes near `src/Index.sol`.
///
/// Arcus spot is RFQ, not an AMM: there is no function to call that returns a fill. The taker
/// only *signs* an intent (Permit2 `PermitWitnessTransferFrom` with a `TakerIntent` witness) and
/// the router's relayer submits the settlement transaction. Permit2's `SignatureVerification`
/// takes the ERC-1271 branch whenever the signer has code, so a contract can be that taker: it
/// vouches for a digest instead of producing a signature.
///
/// The consequence that makes this worth doing: the sell leg is pulled from here and the buy leg
/// is delivered back here, inside one transaction. The assets never sit at a desk, so there is no
/// custody gap and no "in transit" slice that redemption cannot see.
///
/// ponytail: no `acrus_test/interfaces/IArcusVault.sol` — the guide's interface split is for
/// `src/`, and this is a throwaway probe. Promote it when the design moves into `Index.sol`.
contract ArcusVault {
    /// @dev EIP-1271 magic value: `bytes4(keccak256("isValidSignature(bytes32,bytes)"))`.
    bytes4 internal constant MAGIC = 0x1626ba7e;

    /// @dev Canonical Permit2, same address on every chain (4663 included — see /v1/deployment).
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    /// @dev Arcus's witness struct, exactly as `/v1/quote` returns it in `toSign.types`.
    bytes32 internal constant TAKER_INTENT_TYPEHASH = keccak256(
        "TakerIntent(address taker,address takerSellToken,address takerBuyToken,uint256 sellAmount,uint256 minBuyAmount,bool allowWrapped,uint256 nonce,uint256 deadline)"
    );

    /// @dev Permit2's witness stub with the witness type string appended. Referenced types follow
    ///      the primary type alphabetically, so `TakerIntent` precedes `TokenPermissions`.
    bytes32 internal constant PERMIT_WITNESS_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,TakerIntent witness)TakerIntent(address taker,address takerSellToken,address takerBuyToken,uint256 sellAmount,uint256 minBuyAmount,bool allowWrapped,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    address public immutable owner;

    /// @notice The Arcus settlement contract — the only address that may be the Permit2 spender.
    /// @dev Fixed at deploy so `arm` cannot be pointed at an arbitrary puller.
    address public immutable settlement;

    /// @notice The one intent digest this vault currently vouches for. Zero means nothing is armed.
    /// @dev One at a time on purpose: a second live digest is a second sale nobody voted for.
    bytes32 public armed;

    event Armed(
        bytes32 indexed digest,
        address indexed sellToken,
        address indexed buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint256 deadline
    );
    event Disarmed(bytes32 indexed digest);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error NotOwner();
    error Expired();
    error NoFloor();

    constructor(address owner_, address settlement_) {
        owner = owner_;
        settlement = settlement_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Vouch for one Arcus intent, and let Permit2 pull the sell leg for it.
    /// @dev Terms in, digest out — the vault rebuilds the EIP-712 digest from the terms rather
    ///      than rubber-stamping an opaque hash handed to it. That is the whole point: a keeper
    ///      that could arm any digest could sell anything at any price.
    ///      Take `nonce` and `deadline` from `/v1/quote`'s `toSign.message`; they are the router's.
    /// @return digest the Permit2 digest now armed — the caller must check it against the digest
    ///         it derived from the quote itself before submitting.
    function arm(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint256 nonce,
        uint256 deadline
    ) external onlyOwner returns (bytes32 digest) {
        if (deadline <= block.timestamp) revert Expired();
        // A zero floor is a signed blank cheque: the maker could return one raw unit.
        if (minBuyAmount == 0) revert NoFloor();

        // `allowWrapped` is hashed as false, never taken as an argument. Arcus may otherwise
        // settle illiquid names in a wrapped placeholder a maker redeems later, and the pot must
        // hold canonical tokens only (ARCUS-INTEGRATION.md rule 2).
        bytes32 witness = keccak256(
            abi.encode(
                TAKER_INTENT_TYPEHASH,
                address(this),
                sellToken,
                buyToken,
                sellAmount,
                minBuyAmount,
                false,
                nonce,
                deadline
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_WITNESS_TYPEHASH,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, sellToken, sellAmount)),
                settlement,
                nonce,
                deadline,
                witness
            )
        );
        digest = keccak256(abi.encodePacked("\x19\x01", IPermit2(PERMIT2).DOMAIN_SEPARATOR(), structHash));

        armed = digest;
        // ponytail: plain `approve` to exactly `sellAmount`, not max — the allowance expires with
        // the sale instead of standing forever. Non-standard tokens that require a zero-first
        // approve would need the two-step dance; the canonical stock tokens are standard ERC-20.
        IERC20(sellToken).approve(PERMIT2, sellAmount);

        emit Armed(digest, sellToken, buyToken, sellAmount, minBuyAmount, deadline);
    }

    /// @notice Drop the armed digest before its deadline.
    function disarm() external onlyOwner {
        emit Disarmed(armed);
        armed = 0;
    }

    /// @notice ERC-1271. Permit2 calls this with the digest it computed itself; a match means the
    ///         terms it is about to enforce are the terms this vault armed.
    /// @dev The signature bytes are ignored — there is no key here, the storage slot *is* the
    ///      signature. Submit `"0x"` to the router.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        // `armed == 0` would otherwise vouch for the zero digest.
        if (armed != 0 && hash == armed) return MAGIC;
        return 0xffffffff;
    }

    /// @notice Get tokens back out of the probe.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
        emit Withdrawn(token, to, amount);
    }
}
