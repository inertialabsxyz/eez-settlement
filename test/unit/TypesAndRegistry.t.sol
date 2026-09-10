// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SettlementFixture} from "../helpers/SettlementFixture.sol";
import {Book, IExecutor} from "../../src/Book.sol";
import {Trade, SignedIntent, SettlementEIP712} from "../../src/SettlementTypes.sol";

/// `ECDSA.recover` is `internal`, and `vm.expectRevert` binds to the next
/// *external* call. Without this wrapper the expectation would land on whatever
/// external call the test made next and pass for the wrong reason.
contract RecoverProbe {
    function recover(bytes32 digest, bytes calldata signature) external pure returns (address) {
        return ECDSA.recover(digest, signature);
    }
}

/// Step 2a — types, EIP-712 and `TokenRegistry`.
///
/// Three representations of the same order exist deliberately (§5.1.1, §5.2,
/// §5.3): `Intent` in L2 storage keyed by `uint24` registry id, `Trade` in the
/// cross-chain payload keyed by `uint8` index, and `SignedIntent` — the only
/// canonical one — keyed by address. The other two are encodings chosen for
/// storage cost and calldata size, and both must reduce to `SignedIntent`
/// exactly. These tests pin that reduction and the single shared EIP-712
/// definition that both chains compute against.
contract TypesAndRegistryTest is SettlementFixture {
    /// The literal type string from §5.3. Written out here rather than derived,
    /// so that narrowing a field in `SettlementTypes.sol` breaks this test.
    string internal constant INTENT_TYPE_STRING = "Intent(address account,address sellToken,address buyToken,"
        "uint256 sellAmount,uint256 limit,uint256 deadline,uint256 nonce)";

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// An L1 chain id deliberately different from `block.chainid`, so that a
    /// separator pinned to the wrong one is visible.
    uint256 internal constant FOREIGN_L1 = 1;

    RecoverProbe internal probe;

    function setUp() public virtual override {
        super.setUp();
        probe = new RecoverProbe();
    }

    /// The domain, built by hand from the four fields in §5.3 rather than by
    /// calling the library under test.
    function _handBuiltDomain(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("EEZ Settlement")), keccak256(bytes("1")), chainId, verifyingContract
            )
        );
    }

    // ------------------------------------------------------------------
    // 1. SettlementEIP712 — domain separator (§5.3)
    // ------------------------------------------------------------------

    /// §5.3: the domain is `("EEZ Settlement", "1", l1ChainId, executor)`.
    function testDomainSeparatorMatchesHandConstructedDomain() public view {
        assertEq(
            book.domainSeparator(),
            _handBuiltDomain(block.chainid, address(ex)),
            "domain separator is not the EIP-712 domain of (name, version, l1ChainId, executor)"
        );
        assertEq(ex.domainSeparator(), _handBuiltDomain(block.chainid, address(ex)));
    }

    /// §5.3: `Book` reproduces the **L1** chain id it was deployed against and
    /// must not derive one from its own chain. The fixture's `Book` is built
    /// with `block.chainid`, which cannot distinguish the two — so this deploys
    /// one against a foreign L1 to make the pin observable.
    function testDomainSeparatorPinnedToL1ChainIdNotBooksOwn() public {
        Book foreign = new Book(IExecutor(address(ex)), reg, FOREIGN_L1);

        assertEq(foreign.domainSeparator(), _handBuiltDomain(FOREIGN_L1, address(ex)));
        assertTrue(
            foreign.domainSeparator() != _handBuiltDomain(block.chainid, address(ex)),
            "Book derived the domain from its own chain id instead of L1's"
        );
    }

    /// §5.3: the signature is consumed on L1, so `verifyingContract` is
    /// `Executor` — never `Book`, which only checks it to fail fast.
    function testDomainSeparatorPinnedToExecutorNotBook() public {
        Book foreign = new Book(IExecutor(address(ex)), reg, FOREIGN_L1);

        assertTrue(
            foreign.domainSeparator() != _handBuiltDomain(FOREIGN_L1, address(foreign)),
            "Book pinned the domain to itself instead of Executor"
        );
    }

    // ------------------------------------------------------------------
    // 2. SettlementEIP712 — struct hash (§5.3)
    // ------------------------------------------------------------------

    /// §5.3: `INTENT_TYPEHASH` is `keccak256` of the literal type string.
    function testIntentTypehashMatchesLiteralTypeString() public pure {
        assertEq(SettlementEIP712.INTENT_TYPEHASH, keccak256(bytes(INTENT_TYPE_STRING)));
    }

    /// §5.3: every numeric field is `uint256` even though `Trade` and `Intent`
    /// carry them narrow — `encodeData` pads to 32 bytes regardless, and
    /// non-standard widths are unevenly supported by wallet signing libraries.
    /// Narrowing any of them changes what wallets hash and render, so it is
    /// pinned here rather than left to review.
    function testIntentTypeStringUsesUint256ForEveryNumericField() public pure {
        bytes32 narrowed = keccak256(
            bytes(
                "Intent(address account,address sellToken,address buyToken,"
                "uint128 sellAmount,uint128 limit,uint40 deadline,uint64 nonce)"
            )
        );
        assertTrue(
            SettlementEIP712.INTENT_TYPEHASH != narrowed,
            "type string was narrowed to the payload widths; wallets would render a different message"
        );
    }

    /// §5.3: `hashStruct` is `encodeData` over the typehash and all seven
    /// fields, in declaration order.
    function testIntentStructHashIsTypehashPlusAllSevenFields() public view {
        SignedIntent memory i = _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 7);

        bytes32 expected = keccak256(
            abi.encode(
                SettlementEIP712.INTENT_TYPEHASH,
                i.account,
                i.sellToken,
                i.buyToken,
                i.sellAmount,
                i.limit,
                i.deadline,
                i.nonce
            )
        );
        assertEq(SettlementEIP712.digest(book.domainSeparator(), i), _toTypedDataHash(book.domainSeparator(), expected));
    }

    function _toTypedDataHash(bytes32 separator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", separator, structHash));
    }

    // ------------------------------------------------------------------
    // 3. Digest agreement — the seam the shared library exists to protect
    // ------------------------------------------------------------------

    /// §5.3: `Book` verifies at submission to fail fast, `Executor` verifies
    /// again at pull time because that is the check that survives a compromised
    /// L2 (I9). Both compute through `SettlementEIP712` and neither writes its
    /// own — a divergence would pass on L2 and fail on L1 after the batch had
    /// already crossed.
    function testBookAndExecutorAgreeOnDomainSeparator() public view {
        assertEq(book.domainSeparator(), ex.domainSeparator());
    }

    /// The same seam, over arbitrary intents: the two chains must derive
    /// byte-identical digests, and a signature produced against `Book`'s domain
    /// must recover to the signer under `Executor`'s.
    function testFuzzBookAndExecutorDeriveIdenticalDigests(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 limit,
        uint256 deadline,
        uint256 nonce
    ) public view {
        SignedIntent memory i = SignedIntent(alice, sellToken, buyToken, sellAmount, limit, deadline, nonce);

        bytes32 onL2 = SettlementEIP712.digest(book.domainSeparator(), i);
        bytes32 onL1 = SettlementEIP712.digest(ex.domainSeparator(), i);

        assertEq(onL2, onL1, "Book and Executor derived different digests for the same SignedIntent");
    }

    /// I9: what the user signed on L2 is what authorises the pull on L1.
    function testSignatureMadeForBookRecoversUnderExecutorsDomain() public view {
        SignedIntent memory i = _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0);
        bytes memory sig = _signIntent(alicePk, i);

        assertEq(ECDSA.recover(SettlementEIP712.digest(ex.domainSeparator(), i), sig), alice);
    }

    // ------------------------------------------------------------------
    // 4. Fork re-derivation (§5.3, Appendix B)
    // ------------------------------------------------------------------

    /// Appendix B: `Executor` caches the separator behind a chain-id check and
    /// re-derives across a chain split, rather than caching blindly.
    function testExecutorReDerivesSeparatorOnFork() public {
        bytes32 beforeFork = ex.domainSeparator();

        vm.chainId(block.chainid + 1);

        bytes32 afterFork = ex.domainSeparator();
        assertTrue(beforeFork != afterFork, "Executor served its cached separator on a forked chain");
        assertEq(afterFork, _handBuiltDomain(block.chainid, address(ex)));
    }

    /// The reason the check exists: a signature from the original chain must not
    /// authorise a pull on the fork.
    function testSignatureDoesNotReplayOnFork() public {
        SignedIntent memory i = _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0);
        bytes memory sig = _signIntent(alicePk, i);

        vm.chainId(block.chainid + 1);

        address recovered = ECDSA.recover(SettlementEIP712.digest(ex.domainSeparator(), i), sig);
        assertTrue(recovered != alice, "a pre-fork signature still recovers to the signer on the fork");
    }

    // ------------------------------------------------------------------
    // 5. Signature malleability
    // ------------------------------------------------------------------

    /// secp256k1 group order. For any valid `(r, s, v)` the pair `(r, n - s)`
    /// with `v` flipped recovers the same address, which would make a signature
    /// non-unique. OpenZeppelin's `ECDSA.recover` **reverts** on high `s` rather
    /// than returning `address(0)`; both halves of that are pinned here, because
    /// `Book` and `Executor` both treat a non-reverting mismatch as a plain bad
    /// signature and a change would be silent.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function _malleate(bytes memory sig) internal pure returns (bytes memory, bytes32) {
        (bytes32 r, bytes32 s, uint8 v) = (bytes32(0), bytes32(0), 0);
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flipped = v == 27 ? 28 : 27;
        return (abi.encodePacked(r, highS, flipped), highS);
    }

    function testHighSSignatureRejected() public {
        SignedIntent memory i = _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0);
        bytes32 digest = SettlementEIP712.digest(book.domainSeparator(), i);
        (bytes memory malleable, bytes32 highS) = _malleate(_signIntent(alicePk, i));

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        probe.recover(digest, malleable);
    }

    /// The same rejection on the real L2 path, so that the fail-fast check in
    /// `submitIntent` cannot be satisfied by a second signature over the same
    /// intent.
    function testHighSSignatureRejectedAtBookSubmit() public {
        SignedIntent memory i = _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0);
        (bytes memory malleable, bytes32 highS) = _malleate(_signIntent(alicePk, i));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        book.submitIntent(i, malleable);
    }

    // ------------------------------------------------------------------
    // 8. Widening (§5.2, Appendix B `_verifyAndPull`)
    // ------------------------------------------------------------------

    /// §5.2: `Trade` is an encoding of `SignedIntent` chosen for calldata size,
    /// and the narrow payload widths widen implicitly into the signed form.
    /// This reproduces exactly what `Executor._verifyAndPull` does and asserts
    /// the widening is lossless and digest-preserving — if it were not, a user
    /// would be authorising terms other than the ones executed (I9).
    function testFuzzTradeWidensIntoSignedIntentWithoutLoss(
        address account,
        address sellToken,
        address buyToken,
        uint128 sellAmount,
        uint128 limit,
        uint40 deadline,
        uint64 nonce
    ) public view {
        address[] memory tokens = new address[](2);
        tokens[0] = sellToken;
        tokens[1] = buyToken;

        Trade memory t = Trade(account, 0, 1, sellAmount, limit, deadline, nonce);

        SignedIntent memory widened = SignedIntent({
            account: t.account,
            sellToken: tokens[t.sellIdx],
            buyToken: tokens[t.buyIdx],
            sellAmount: t.sellAmount,
            limit: t.limit,
            deadline: t.deadline,
            nonce: t.nonce
        });

        SignedIntent memory direct = SignedIntent({
            account: account,
            sellToken: sellToken,
            buyToken: buyToken,
            sellAmount: uint256(sellAmount),
            limit: uint256(limit),
            deadline: uint256(deadline),
            nonce: uint256(nonce)
        });

        assertEq(widened.sellAmount, uint256(sellAmount), "uint128 sellAmount lost value widening to uint256");
        assertEq(widened.limit, uint256(limit), "uint128 limit lost value widening to uint256");
        assertEq(widened.deadline, uint256(deadline), "uint40 deadline lost value widening to uint256");
        assertEq(widened.nonce, uint256(nonce), "uint64 nonce lost value widening to uint256");

        bytes32 separator = book.domainSeparator();
        assertEq(SettlementEIP712.digest(separator, widened), SettlementEIP712.digest(separator, direct));
    }
}
