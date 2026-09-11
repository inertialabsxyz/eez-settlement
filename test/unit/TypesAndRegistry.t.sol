// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SettlementFixture, ProxyEEZ} from "../helpers/SettlementFixture.sol";
import {Book, IExecutor} from "../../src/Book.sol";
import {Executor} from "../../src/Executor.sol";
import {Trade, Interaction, SettlementData, SignedIntent, SettlementEIP712} from "../../src/SettlementTypes.sol";
import {TokenRegistry} from "../../src/TokenRegistry.sol";

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
        Book foreign = new Book(eez, address(ex), 0, reg, FOREIGN_L1);

        assertEq(foreign.domainSeparator(), _handBuiltDomain(FOREIGN_L1, address(ex)));
        assertTrue(
            foreign.domainSeparator() != _handBuiltDomain(block.chainid, address(ex)),
            "Book derived the domain from its own chain id instead of L1's"
        );
    }

    /// §5.3: the signature is consumed on L1, so `verifyingContract` is
    /// `Executor` — never `Book`, which only checks it to fail fast.
    function testDomainSeparatorPinnedToExecutorNotBook() public {
        Book foreign = new Book(eez, address(ex), 0, reg, FOREIGN_L1);

        assertTrue(
            foreign.domainSeparator() != _handBuiltDomain(FOREIGN_L1, address(foreign)),
            "Book pinned the domain to itself instead of Executor"
        );
    }

    /// §5.3: `verifyingContract` is the **L1 `Executor`** — the contract that
    /// consumes the signature — and not the cross-chain proxy `Book` dispatches
    /// to. Those are two different addresses on a real bridge; the fixture's
    /// `IdEEZ` collapses them, so this rebuilds `Book` over a derivation that
    /// keeps them apart.
    ///
    /// Without this case a `Book` that scoped the domain to its dispatch target
    /// passed every suite here and rejected nothing, while every settlement it
    /// produced died on L1 with `BadSignature(0)` — silent on L2, fatal after
    /// the batch had already crossed.
    function testDomainSeparatorPinnedToL1ExecutorNotItsCrossChainProxy() public {
        address realEez = address(new ProxyEEZ());
        Executor l1Ex = new Executor(realEez, 0, windfall);
        Book b = new Book(realEez, address(l1Ex), 0, reg, block.chainid);

        assertTrue(
            address(b.executor()) != b.l1Executor(),
            "ProxyEEZ did not derive a distinct proxy; this test proves nothing"
        );
        assertEq(b.l1Executor(), address(l1Ex), "Book did not record the L1 Executor");

        // The check that matters: the two chains agree on what was signed.
        assertEq(
            b.domainSeparator(),
            l1Ex.domainSeparator(),
            "Book's domain does not match the Executor that consumes the signature"
        );
        assertEq(b.domainSeparator(), _handBuiltDomain(block.chainid, address(l1Ex)));
        assertTrue(
            b.domainSeparator() != _handBuiltDomain(block.chainid, address(b.executor())),
            "Book scoped the domain to its cross-chain proxy instead of the L1 Executor"
        );
    }

    /// The other half of the same derivation: `Book` dispatches to the proxy,
    /// not to the L1 address. A `Book` holding the raw L1 address would emit a
    /// call to an account with no code on L2.
    function testBookDispatchesToTheCrossChainProxy() public {
        address realEez = address(new ProxyEEZ());
        Executor l1Ex = new Executor(realEez, 0, windfall);
        Book b = new Book(realEez, address(l1Ex), 0, reg, block.chainid);

        assertEq(
            address(b.executor()),
            ProxyEEZ(realEez).computeCrossChainProxyAddress(address(l1Ex), 0),
            "Book did not dispatch to the derived cross-chain proxy"
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

    /// §5.3, I9: the same seam, over arbitrary intents. Both chains compute
    /// through `SettlementEIP712` and neither writes its own, so the digests
    /// must be byte-identical for every `SignedIntent` — a divergence would pass
    /// on L2 at submission and fail on L1 after the batch had already crossed.
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

    /// §5.3, I9: the reason the check exists. The domain binds the L1 chain id
    /// precisely so that a signature from the original chain does not authorise
    /// a pull on the fork.
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
    /// with `v` flipped recovers the same address, which is what would make a
    /// signature non-unique.
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

    /// I9, Appendix B `_verifyAndPull`: `Executor` relies on OpenZeppelin's
    /// `ECDSA.recover` **reverting** on high `s` rather than returning
    /// `address(0)` — its own check is only `recovered != t.account`, so a
    /// second valid signature over the same terms would otherwise be a second
    /// authorisation. Both halves of that behaviour are pinned here, because a
    /// change in either would be silent.
    function testHighSSignatureRejected() public {
        SignedIntent memory i = _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0);
        bytes32 digest = SettlementEIP712.digest(book.domainSeparator(), i);
        (bytes memory malleable, bytes32 highS) = _malleate(_signIntent(alicePk, i));

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        probe.recover(digest, malleable);
    }

    /// §5.3, I9: the same rejection on the real L2 path. `Book`'s fail-fast
    /// check at submission goes through the same `ECDSA.recover`, so it cannot
    /// be satisfied by a second, malleated signature over the same intent.
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

    /// §5.2, I9: the same widening, but performed by `Executor` rather than by
    /// this test. `_verifyAndPull` rebuilds the `SignedIntent` from the narrow
    /// `Trade` and recovers against it, so a reconstruction that lost a value,
    /// reordered a field or used a narrowed type string would derive a digest
    /// other than the one the user signed and revert `BadSignature`. The
    /// signature is made against `book.domainSeparator()`, so this exercises the
    /// cross-chain seam on the real path as well.
    ///
    /// A single unmatched trade cannot balance, so the settlement is expected to
    /// fail further down `verify -> pull -> interact -> pay -> restore`. The
    /// assertion is on *which* revert, not on success.
    function testFuzzExecutorWidensTradeIntoTheSignedIntentTheUserSigned(
        uint128 sellAmount,
        uint128 limit,
        uint40 deadline,
        uint64 nonce
    ) public {
        deadline = uint40(bound(deadline, block.timestamp, type(uint40).max));

        SignedIntent memory widened = SignedIntent({
            account: alice,
            sellToken: address(usdc),
            buyToken: address(weth),
            sellAmount: uint256(sellAmount),
            limit: uint256(limit),
            deadline: uint256(deadline),
            nonce: uint256(nonce)
        });

        Trade[] memory trades = new Trade[](1);
        trades[0] = Trade(alice, 0, 1, sellAmount, limit, deadline, nonce);

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signIntent(alicePk, widened);

        SettlementData memory d = SettlementData(_tokens2(), _prices2(), trades, new Interaction[](0));

        vm.prank(address(book));
        (bool ok, bytes memory err) = address(ex).call(abi.encodeCall(Executor.settle, (d, sigs)));

        if (!ok) {
            assertTrue(
                bytes4(err) != Executor.BadSignature.selector,
                "Executor rebuilt a digest from the narrow Trade that the user never signed"
            );
        }
    }

    // ------------------------------------------------------------------
    // 6. TokenRegistry — id semantics (§5.1.1, Appendix E)
    // ------------------------------------------------------------------

    /// §5.1.1: `id == index`. A fresh registry hands out 0 first, so the id can
    /// be used to index `tokens` directly.
    function testFirstRegistrationIsIdZero() public {
        TokenRegistry fresh = new TokenRegistry();

        assertEq(fresh.register(address(usdc)), 0);
        assertEq(fresh.register(address(weth)), 1);
        assertEq(fresh.register(address(dai)), 2);
    }

    /// §5.1.1: `id == index` — the id is the position in `tokens`, which is what
    /// lets `Intent` compress to two slots.
    function testIdEqualsIndex() public view {
        for (uint24 i = 0; i < uint24(reg.count()); i++) {
            (uint24 id, bool found) = reg.idOf(reg.tokens(i));
            assertTrue(found);
            assertEq(id, i, "id diverged from index");
            assertEq(reg.tokenAt(i), reg.tokens(i));
        }
    }

    /// §5.1.1: registration is idempotent, so a token cannot acquire two ids.
    /// Not a safety issue — `Book` resolves id to address before matching a
    /// trade — but wasteful and confusing.
    function testRegisterIsIdempotent() public {
        TokenRegistry fresh = new TokenRegistry();

        uint24 first = fresh.register(address(usdc));
        assertEq(fresh.register(address(usdc)), first);
        assertEq(fresh.register(address(usdc)), first);
        assertEq(fresh.count(), 1, "an idempotent re-registration still grew the registry");
    }

    /// §5.1.1: this distinction is the entire reason `idOf` returns two values.
    /// Id 0 is a legitimate token, so a bare zero return cannot tell "the first
    /// token registered" from "not here" — the two cases below differ only in
    /// `found`.
    function testIdOfDistinguishesUnregisteredFromIdZero() public {
        TokenRegistry fresh = new TokenRegistry();

        (uint24 id, bool found) = fresh.idOf(address(usdc));
        assertEq(id, 0);
        assertFalse(found, "an unregistered token reported as found");

        fresh.register(address(usdc));

        (id, found) = fresh.idOf(address(usdc));
        assertEq(id, 0, "the first registered token did not hold id 0");
        assertTrue(found, "the token holding id 0 reported as absent");
    }

    /// §5.1.1: the registry is append-only, so an id once handed out never
    /// moves. `Intent` stores the id, not the address, so a shifting id would
    /// silently repoint every intent already in storage.
    function testIdsAreStableAcrossLaterRegistrations() public {
        TokenRegistry fresh = new TokenRegistry();

        uint24 usdcId = fresh.register(address(usdc));
        fresh.register(address(weth));
        fresh.register(address(dai));

        (uint24 id, bool found) = fresh.idOf(address(usdc));
        assertTrue(found);
        assertEq(id, usdcId, "an earlier id moved when a later token was registered");
        assertEq(fresh.tokenAt(usdcId), address(usdc));
    }

    // ------------------------------------------------------------------
    // 7. TokenRegistry — bounds (§5.1.1, Appendix E)
    // ------------------------------------------------------------------

    /// Appendix E: `tokenAt` reverts `UnknownId` past the end rather than
    /// reading out of bounds.
    function testTokenAtRevertsUnknownIdPastTheEnd() public {
        uint24 pastEnd = uint24(reg.count());

        vm.expectRevert(TokenRegistry.UnknownId.selector);
        reg.tokenAt(pastEnd);
    }

    /// §5.1.1, Appendix E: the same on an empty registry, where every id is
    /// past the end — id 0 included, which the `id >= tokens.length` bound
    /// covers and an `id == 0` sentinel would not.
    function testTokenAtRevertsOnEmptyRegistry() public {
        TokenRegistry fresh = new TokenRegistry();

        vm.expectRevert(TokenRegistry.UnknownId.selector);
        fresh.tokenAt(0);
    }

    /// Appendix E: `register(address(0))` reverts `ZeroAddress`. The zero
    /// address would otherwise take a real id and index a token that cannot be
    /// transferred.
    function testRegisterZeroAddressReverts() public {
        vm.expectRevert(TokenRegistry.ZeroAddress.selector);
        reg.register(address(0));
    }

    /// Fuzzed over the whole address space: every non-zero address registers and
    /// round-trips, and the zero address never does. Registration is
    /// permissionless and ungoverned — an id confers nothing (§5.1.1), so there
    /// is no eligibility check to pass.
    function testFuzzRegisterRoundTrips(address token) public {
        TokenRegistry fresh = new TokenRegistry();

        if (token == address(0)) {
            vm.expectRevert(TokenRegistry.ZeroAddress.selector);
            fresh.register(token);
            return;
        }

        uint24 id = fresh.register(token);
        assertEq(id, 0);
        assertEq(fresh.tokenAt(id), token);

        (uint24 got, bool found) = fresh.idOf(token);
        assertTrue(found);
        assertEq(got, id);
    }
}
