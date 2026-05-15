// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";
import {EvolutionTypes} from "../src/hooks/EvolutionTypes.sol";
import {IAgentEvolutionHook} from "../src/hooks/IAgentEvolutionHook.sol";
import {BaseEvolutionHook} from "../src/hooks/BaseEvolutionHook.sol";
import {TransferRecolorHook} from "../src/hooks/TransferRecolorHook.sol";

/// @dev Hook that always returns the wrong selector — used to verify the host
///      reverts with HookInvalidReturn.
contract BadSelectorHook is BaseEvolutionHook {
    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_AFTER_MINT;
    }
    function afterMint(uint256, address, bytes calldata) external pure override returns (bytes4) {
        return bytes4(0xdeadbeef);
    }
}

/// @dev Hook that reverts in beforeTransfer — used to verify transfers are blocked.
contract SoulboundHook is BaseEvolutionHook {
    error TransferBlocked();
    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_BEFORE_TRANSFER;
    }
    function beforeTransfer(uint256, address, address) external pure override returns (bytes4) {
        revert TransferBlocked();
    }
}

/// @dev Hook that declares FLAG_REQUIRES_KEEPER so the host emits
///      `EvolutionRequested` instead of applying results inline. Used only to
///      exercise the oracle-published `commitEvolution` path — NOT part of the
///      main v4-style on-chain hook library.
contract OracleCommitHook is BaseEvolutionHook {
    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER | EvolutionTypes.FLAG_REQUIRES_KEEPER;
    }
    function onTrigger(uint256, bytes32, bytes calldata)
        external
        pure
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        r.requiresKeeper = true;
        return r;
    }
}

contract EvolutionHooksTest is Test {
    AgentCollectionFactory factory;
    AgentCollectionImpl    impl;
    AgentCollectionImpl    collection;

    address owner    = address(0x1);
    address protocol = address(0x2);
    address creator  = address(0x3);
    address minter   = address(0x4);
    address buyer    = address(0x5);

    uint256 keeperPk = 0xA11CE;
    address keeper;

    TransferRecolorHook recolor;
    OracleCommitHook   kHook;

    function setUp() public {
        keeper = vm.addr(keeperPk);

        vm.startPrank(owner);
        impl = new AgentCollectionImpl();
        factory = new AgentCollectionFactory(address(impl), protocol);
        vm.stopPrank();

        vm.prank(creator);
        (, address addr) = factory.createCollection("Hooked", "HOOK", 100, 1000, 500, "");
        collection = AgentCollectionImpl(addr);

        recolor = new TransferRecolorHook();
        kHook   = new OracleCommitHook();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Hook setters: auth, validation, permission caching
    // ─────────────────────────────────────────────────────────────────────────

    function test_setCollectionHook_onlyCreator() public {
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.NotCreator.selector);
        collection.setCollectionHook(address(recolor));

        vm.prank(creator);
        collection.setCollectionHook(address(recolor));
        assertEq(collection.collectionHook(), address(recolor));
        assertEq(collection.hookPermissions(address(recolor)), recolor.getPermissions());
    }

    function test_setCollectionHook_invalidAddress() public {
        vm.prank(creator);
        vm.expectRevert(AgentCollectionImpl.HookAddressInvalid.selector);
        collection.setCollectionHook(address(0xBEEF)); // EOA → no code
    }

    function test_setHook_perAgent_overridesCollection() public {
        vm.prank(creator);
        collection.setCollectionHook(address(kHook));

        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        // Per-agent override
        vm.prank(minter);
        collection.setHook(id, address(recolor));

        (address active,) = collection.activeHookFor(id);
        assertEq(active, address(recolor));
    }

    function test_setHook_onlyOwner() public {
        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        vm.prank(buyer);
        vm.expectRevert(AgentCollectionImpl.NotOwner.selector);
        collection.setHook(id, address(recolor));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lifecycle: afterTransfer fires on transfers but NOT on mints
    // ─────────────────────────────────────────────────────────────────────────

    function test_afterTransfer_firesOnTransfer_notOnMint() public {
        vm.prank(creator);
        collection.setCollectionHook(address(recolor));

        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        // Mint did NOT count as a transfer
        assertEq(recolor.transferCount(id), 0);

        vm.prank(minter);
        collection.transferFrom(minter, buyer, id);

        assertEq(recolor.transferCount(id), 1);
    }

    function test_beforeTransfer_canBlockTransfer() public {
        SoulboundHook sb = new SoulboundHook();
        vm.prank(creator);
        collection.setCollectionHook(address(sb));

        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        vm.prank(minter);
        vm.expectRevert(SoulboundHook.TransferBlocked.selector);
        collection.transferFrom(minter, buyer, id);
    }

    function test_afterMint_invalidReturnSelector_revertsMint() public {
        BadSelectorHook bad = new BadSelectorHook();
        vm.prank(creator);
        collection.setCollectionHook(address(bad));

        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.HookInvalidReturn.selector);
        collection.registerAgent("A", "uri");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // triggerEvolve: inline mutation path
    // ─────────────────────────────────────────────────────────────────────────

    function test_triggerEvolve_inlineMutation() public {
        vm.prank(creator);
        collection.setCollectionHook(address(recolor));

        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        // Two transfers → counter = 2
        vm.prank(minter);
        collection.transferFrom(minter, buyer, id);
        vm.prank(buyer);
        collection.transferFrom(buyer, minter, id);

        assertFalse(collection.hasSVGImage(id));

        // Anyone can call triggerEvolve
        vm.prank(address(0xDEAD));
        collection.triggerEvolve(id, EvolutionTypes.TRIGGER_TRANSFER, "");

        assertTrue(collection.hasSVGImage(id));
        // Hue should be (2 * 47) % 360 = 94
        string memory svg = collection.getSVGImage(id);
        assertEq(_indexOf(svg, "hsl(94"), 1, "expected hue 94 in inline svg");

        // State hash recorded
        assertTrue(collection.evolutionStateHash(id) != bytes32(0));
    }

    function test_triggerEvolve_revertsWithoutHook() public {
        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        vm.expectRevert(AgentCollectionImpl.HookAddressInvalid.selector);
        collection.triggerEvolve(id, EvolutionTypes.TRIGGER_TRANSFER, "");
    }

    function test_triggerEvolve_revertsWithoutOnTriggerFlag() public {
        // Soulbound hook only declares FLAG_BEFORE_TRANSFER, no FLAG_ON_TRIGGER
        SoulboundHook sb = new SoulboundHook();
        vm.prank(creator);
        collection.setCollectionHook(address(sb));

        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        vm.expectRevert(abi.encodeWithSelector(
            AgentCollectionImpl.HookPermissionMissing.selector,
            EvolutionTypes.FLAG_ON_TRIGGER
        ));
        collection.triggerEvolve(id, EvolutionTypes.TRIGGER_TRANSFER, "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Keeper path: triggerEvolve emits EvolutionRequested + commitEvolution
    // ─────────────────────────────────────────────────────────────────────────

    function test_keeperFlow_triggerRequests_commitFinalises() public {
        vm.startPrank(creator);
        collection.setCollectionHook(address(kHook));
        collection.setEvolutionKeeper(keeper);
        vm.stopPrank();

        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        // 1) Trigger should emit EvolutionRequested with nonce=1
        bytes memory payload = abi.encode("level-up", uint256(42));
        vm.expectEmit(true, true, false, true);
        emit AgentCollectionImpl.EvolutionRequested(id, EvolutionTypes.TRIGGER_SERVICE_X402, 1, payload);
        collection.triggerEvolve(id, EvolutionTypes.TRIGGER_SERVICE_X402, payload);
        assertEq(collection.commitNonce(id), 1);

        // 2) Keeper signs an EvolutionResult that mutates the URI
        EvolutionTypes.EvolutionResult memory r = EvolutionTypes.EvolutionResult({
            svgChanged:    true,
            newSvgUri:     "ipfs://new-cid",
            newSvgInline:  "",
            newStateHash:  keccak256("level-2"),
            requiresKeeper: false
        });

        uint256 nonce    = 2;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCommit(id, EvolutionTypes.TRIGGER_SERVICE_X402, r, nonce, deadline);

        collection.commitEvolution(id, EvolutionTypes.TRIGGER_SERVICE_X402, r, nonce, deadline, sig);

        assertEq(collection.commitNonce(id), nonce);
        assertEq(collection.evolutionStateHash(id), r.newStateHash);
        // tokenURI should now be the new URI (no on-chain SVG, so super.tokenURI returns _setTokenURI value)
        assertEq(collection.tokenURI(id), "ipfs://new-cid");
    }

    function test_commitEvolution_replayReverts() public {
        vm.startPrank(creator);
        collection.setCollectionHook(address(kHook));
        collection.setEvolutionKeeper(keeper);
        vm.stopPrank();

        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        EvolutionTypes.EvolutionResult memory r;
        r.svgChanged   = true;
        r.newSvgUri    = "ipfs://x";
        r.newStateHash = keccak256("x");

        uint256 nonce    = 1;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCommit(id, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline);

        collection.commitEvolution(id, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline, sig);

        // Replay with same nonce → reverts
        vm.expectRevert(AgentCollectionImpl.HookNonceUsed.selector);
        collection.commitEvolution(id, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline, sig);
    }

    function test_commitEvolution_expiredDeadline() public {
        vm.startPrank(creator);
        collection.setCollectionHook(address(kHook));
        collection.setEvolutionKeeper(keeper);
        vm.stopPrank();

        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        EvolutionTypes.EvolutionResult memory r;
        r.svgChanged = true;
        r.newSvgUri  = "ipfs://x";

        uint256 nonce    = 1;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCommit(id, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(AgentCollectionImpl.HookSignatureExpired.selector);
        collection.commitEvolution(id, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline, sig);
    }

    function test_commitEvolution_invalidSigner() public {
        vm.startPrank(creator);
        collection.setCollectionHook(address(kHook));
        collection.setEvolutionKeeper(keeper);
        vm.stopPrank();

        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        EvolutionTypes.EvolutionResult memory r;
        r.svgChanged = true;
        r.newSvgUri  = "ipfs://x";

        uint256 nonce    = 1;
        uint256 deadline = block.timestamp + 1 hours;

        // Sign with a DIFFERENT private key
        uint256 wrongPk = 0xBADC0DE;
        bytes32 digest = _commitDigest(id, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline);
        (uint8 v, bytes32 sR, bytes32 sS) = vm.sign(wrongPk, digest);
        bytes memory sig = abi.encodePacked(sR, sS, v);

        vm.expectRevert(AgentCollectionImpl.HookSignatureInvalid.selector);
        collection.commitEvolution(id, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline, sig);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fuzz: any sequence of transfers should leave transferCount accurate
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_transferCount(uint8 n) public {
        n = uint8(bound(n, 0, 20));

        vm.prank(creator);
        collection.setCollectionHook(address(recolor));

        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        address a = minter;
        address b = buyer;
        for (uint8 i = 0; i < n; i++) {
            vm.prank(a);
            collection.transferFrom(a, b, id);
            (a, b) = (b, a);
        }
        assertEq(recolor.transferCount(id), n);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // EIP-712 helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _commitDigest(
        uint256 agentId,
        bytes32 triggerKind,
        EvolutionTypes.EvolutionResult memory r,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 typehash = keccak256(
            "Commit(uint256 agentId,bytes32 triggerKind,bytes32 resultHash,uint256 nonce,uint256 deadline)"
        );
        bytes32 resultHash = keccak256(abi.encode(
            r.svgChanged,
            keccak256(bytes(r.newSvgUri)),
            keccak256(r.newSvgInline),
            r.newStateHash,
            r.requiresKeeper
        ));
        bytes32 structHash = keccak256(abi.encode(
            typehash, agentId, triggerKind, resultHash, nonce, deadline
        ));
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(collection.name())),
            keccak256(bytes("1")),
            block.chainid,
            address(collection)
        ));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _signCommit(
        uint256 agentId,
        bytes32 triggerKind,
        EvolutionTypes.EvolutionResult memory r,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = _commitDigest(agentId, triggerKind, r, nonce, deadline);
        (uint8 v, bytes32 sR, bytes32 sS) = vm.sign(keeperPk, digest);
        return abi.encodePacked(sR, sS, v);
    }

    /// @dev Returns 1 if `needle` appears in `hay`, else 0. Cheap substring search.
    function _indexOf(string memory hay, string memory needle) internal pure returns (uint256) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || h.length < n.length) return 0;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) { ok = false; break; }
            }
            if (ok) return 1;
        }
        return 0;
    }
}
