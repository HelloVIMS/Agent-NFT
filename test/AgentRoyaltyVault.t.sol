// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentRoyaltyVault.sol";

/// @dev Minimal ERC20 for the vault.releaseToken() path.
contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @dev Treasury that refuses ETH (e.g. governance set a contract without receive).
contract RejectingPayee {
    receive() external payable { revert("no"); }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector; // can hold the agent NFT, can't take ETH
    }
}

/// @dev USDC-like token with a blocklist: transfers to a listed address revert.
contract BlocklistToken is ERC20 {
    mapping(address => bool) public blocked;
    constructor() ERC20("Block", "BLK") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function setBlocked(address a, bool b) external { blocked[a] = b; }
    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}

contract AgentRoyaltyVaultTest is Test {
    AgentIdentityRegistry internal registry;
    address internal owner    = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal creator  = makeAddr("creator");
    address internal buyer    = makeAddr("buyer");

    uint256 internal constant DEFAULT_CREATOR_BPS = 1000; // 10%
    uint256 internal constant DEFAULT_SYSTEM_BPS  = 50;   // 0.5%

    function setUp() public {
        AgentIdentityRegistry impl = new AgentIdentityRegistry();
        bytes memory init = abi.encodeCall(AgentIdentityRegistry.initialize, ());
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        registry = AgentIdentityRegistry(address(proxy));

        // Hand ownership to `owner` and reassign the secondary treasury to
        // the canonical test address. `initialize()` seeded treasury =
        // deployer (this test contract) — the production deploy script
        // does the same and then calls `setSecondaryTreasury` to point at
        // the real treasury.
        registry.transferOwnership(owner);
        vm.prank(owner);
        registry.setSecondaryTreasury(treasury);
    }

    // ============ State / config ============

    function test_InitializedDefaults() public view {
        assertEq(registry.secondaryTreasury(), treasury);
        assertEq(registry.secondarySystemFeeBps(), DEFAULT_SYSTEM_BPS);
    }

    function test_InitializerCannotBeCalledTwice() public {
        vm.expectRevert(); // Initializable: InvalidInitialization
        registry.initialize();
    }

    function test_OnlyOwnerSetsSecondaryTreasury() public {
        address newT = makeAddr("newTreasury");
        vm.prank(buyer);
        vm.expectRevert();
        registry.setSecondaryTreasury(newT);

        vm.prank(owner);
        registry.setSecondaryTreasury(newT);
        assertEq(registry.secondaryTreasury(), newT);
    }

    function test_SetSecondarySystemFeeBpsCappedAt250() public {
        // Hard cap is now 2.5% (250 bps).
        vm.prank(owner);
        vm.expectRevert(AgentIdentityRegistry.InvalidValue.selector);
        registry.setSecondarySystemFeeBps(251);

        vm.prank(owner);
        registry.setSecondarySystemFeeBps(250);
        assertEq(registry.secondarySystemFeeBps(), 250);
    }

    function test_SetSecondaryTreasuryRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(AgentIdentityRegistry.InvalidAddress.selector);
        registry.setSecondaryTreasury(address(0));
    }

    // ============ royaltyInfo / vault address ============

    function test_RoyaltyInfoReturnsVaultAndCombinedBps() public {
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);

        (address receiver, uint256 amount) = registry.royaltyInfo(agentId, 10_000 ether);

        // Vault is the receiver (deterministic, even before deployment).
        assertEq(receiver, registry.royaltyVaultAddress(agentId));

        // (1000 + 50) / 10000 * 10000 ether = 1_050 ether
        assertEq(amount, 1_050 ether);
    }

    function test_RoyaltyVaultAddressIsDeterministic() public {
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);

        address pre  = registry.royaltyVaultAddress(agentId);
        address dep  = registry.deployRoyaltyVault(agentId);
        address post = registry.royaltyVaultAddress(agentId);

        assertEq(pre,  dep);
        assertEq(dep,  post);
        assertGt(dep.code.length, 0);
    }

    function test_DeployRoyaltyVaultIsIdempotent() public {
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);
        address v1 = registry.deployRoyaltyVault(agentId);
        address v2 = registry.deployRoyaltyVault(agentId);
        assertEq(v1, v2);
    }

    function test_DeployRoyaltyVaultRevertsForNonexistentAgent() public {
        vm.expectRevert(AgentIdentityRegistry.NotExists.selector);
        registry.deployRoyaltyVault(999);
    }

    // ============ ETH split ============

    function test_ReleaseSplitsETHProportionally() public {
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));

        // Buyer pays the *combined* royalty amount (1_050 of every 10_000 sale).
        uint256 totalRoyalty = 1_050 ether;
        vm.deal(buyer, totalRoyalty);
        vm.prank(buyer);
        (bool ok,) = address(vault).call{value: totalRoyalty}("");
        assertTrue(ok);

        uint256 creatorBefore  = creator.balance;
        uint256 treasuryBefore = treasury.balance;

        vault.release();

        // Of 1050 ether, treasury gets 50 ether and the creator gets 1000 ether.
        assertEq(treasury.balance - treasuryBefore, 50 ether);
        assertEq(creator.balance  - creatorBefore,  1_000 ether);
        assertEq(address(vault).balance,            0);
    }

    function test_ReleaseRevertsWhenEmpty() public {
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));

        vm.expectRevert(AgentRoyaltyVault.NothingToRelease.selector);
        vault.release();
    }

    function test_ReleaseUsesMintTimeBps() public {
        // Creator royalty is committed at mint (immutable post-mint), but
        // the secondary system fee is governance-mutable. This test pokes
        // the live system-fee path: after the owner raises the system fee
        // from 50 (0.5%) to 250 (2.5% — the cap), `royaltyInfo` and the
        // vault split must reflect the new split deterministically.
        uint256 agentId = _mint(creator, 2500); // creator bps locked at mint
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));

        vm.prank(owner);
        registry.setSecondarySystemFeeBps(250);

        // royaltyInfo: 2500 + 250 = 2750 bps of 10_000 ether = 2_750 ether.
        (, uint256 amount) = registry.royaltyInfo(agentId, 10_000 ether);
        assertEq(amount, 2_750 ether);

        vm.deal(buyer, 2_750 ether);
        vm.prank(buyer);
        (bool ok,) = address(vault).call{value: 2_750 ether}("");
        assertTrue(ok);

        vault.release();

        // treasury: 250/2750 of 2750 = 250 ether. creator: rest.
        assertEq(treasury.balance, 250 ether);
        assertEq(creator.balance,  2_500 ether);
    }

    // ============ ERC20 split ============

    function test_ReleaseTokenSplitsERC20() public {
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));

        MockToken tok = new MockToken();
        tok.mint(address(vault), 1_050 * 1e6);

        vault.releaseToken(tok);

        assertEq(tok.balanceOf(treasury), 50 * 1e6);
        assertEq(tok.balanceOf(creator),  1_000 * 1e6);
        assertEq(tok.balanceOf(address(vault)), 0);
    }

    function test_ReleaseTokenRevertsWhenZero() public {
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));

        MockToken tok = new MockToken();
        vm.expectRevert(AgentRoyaltyVault.NothingToRelease.selector);
        vault.releaseToken(tok);
    }

    // ============ ETH-before-deploy semantics (CREATE2 invariant) ============

    function test_ETHSentBeforeDeploymentIsClaimable() public {
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);
        address predicted = registry.royaltyVaultAddress(agentId);

        // Marketplace sends royalty before vault is deployed.
        vm.deal(buyer, 1_050 ether);
        vm.prank(buyer);
        (bool ok,) = predicted.call{value: 1_050 ether}("");
        assertTrue(ok);
        assertEq(predicted.balance, 1_050 ether);

        // Now anyone deploys the vault.
        registry.deployRoyaltyVault(agentId);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(predicted));

        // Funds survived the deploy (CREATE2 preserves balance).
        assertEq(address(vault).balance, 1_050 ether);

        vault.release();
        assertEq(treasury.balance, 50 ether);
        assertEq(creator.balance,  1_000 ether);
    }

    // ============ Zero creator-bps (creator opts out) ============

    function test_CreatorBpsCanBeZero() public {
        uint256 agentId = _mint(creator, 0);

        // royaltyInfo: 0 + 50 = 50 bps total → only the system fee survives.
        (address receiver, uint256 amount) = registry.royaltyInfo(agentId, 10_000 ether);
        assertEq(receiver, registry.royaltyVaultAddress(agentId));
        assertEq(amount, 50 ether); // 0.5% of 10_000

        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));
        vm.deal(address(vault), 50 ether);
        vault.release();

        // Treasury sweeps everything; creator gets 0.
        assertEq(treasury.balance, 50 ether);
        assertEq(creator.balance,  0);
    }

    function test_CreatorRoyaltyIsImmutablePostMint() public {
        uint256 agentId = _mint(creator, 1000);

        // The legacy `updateCreatorRoyalty(uint256,uint256)` selector is
        // gone — even the creator can't mutate the bps post-mint.
        bytes memory call = abi.encodeWithSignature("updateCreatorRoyalty(uint256,uint256)", agentId, 0);
        vm.prank(creator);
        (bool ok,) = address(registry).call(call);
        assertFalse(ok, "updateCreatorRoyalty should be removed");

        (, uint256 bps) = registry.getCreatorRoyalty(agentId);
        assertEq(bps, 1000); // pinned to mint-time value
    }

    function test_ReleaseRevertsWhenBothBpsAreZero() public {
        uint256 agentId = _mint(creator, 0);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));

        // Owner zeroes the system fee too — degenerate config.
        vm.prank(owner);
        registry.setSecondarySystemFeeBps(0);

        vm.deal(address(vault), 1 ether);
        vm.expectRevert(AgentRoyaltyVault.ZeroBpsConfig.selector);
        vault.release();
    }

    // ============ Fuzz ============

    function testFuzz_RoyaltyInfoMath(uint128 salePrice, uint256 creatorBps) public {
        creatorBps = bound(creatorBps, 0, 5000);
        uint256 agentId = _mint(creator, creatorBps);

        (address receiver, uint256 amount) = registry.royaltyInfo(agentId, salePrice);
        assertEq(receiver, registry.royaltyVaultAddress(agentId));
        assertEq(amount, (uint256(salePrice) * (creatorBps + DEFAULT_SYSTEM_BPS)) / 10_000);
    }

    function testFuzz_SplitProducesNoDust(uint96 totalRoyalty) public {
        vm.assume(totalRoyalty >= 1050); // ratio 50:1000
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));

        vm.deal(address(vault), totalRoyalty);

        uint256 cBefore = creator.balance;
        uint256 tBefore = treasury.balance;
        vault.release();

        uint256 sumOut = (creator.balance - cBefore) + (treasury.balance - tBefore);
        assertEq(sumOut, totalRoyalty); // dust-free
        assertEq(address(vault).balance, 0);
    }

    // ============ Helpers ============

    // ============ M-03: one bad receiver never blocks the other ============

    function test_RejectingTreasuryDefersItsShareCreatorStillPaid() public {
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));
        RejectingPayee bad = new RejectingPayee();
        vm.prank(owner);
        registry.setSecondaryTreasury(address(bad));

        vm.deal(address(vault), 1_050 ether);
        vault.release();
        assertEq(creator.balance, 1_000 ether, "creator paid despite the treasury");
        assertEq(vault.owed(address(0), address(bad)), 50 ether);
        assertEq(vault.totalOwed(address(0)), 50 ether);

        // New royalty splits only the new money, not the deferred share.
        vm.deal(address(vault), address(vault).balance + 105 ether);
        vault.release();
        assertEq(creator.balance, 1_100 ether);
        assertEq(vault.owed(address(0), address(bad)), 55 ether);

        // The stuck payee pulls its share to an address that can take it.
        vm.prank(address(bad));
        vault.withdrawOwed(address(0), treasury);
        assertEq(treasury.balance, 55 ether);
        assertEq(vault.totalOwed(address(0)), 0);
        assertEq(address(vault).balance, 0);
        vm.expectRevert(AgentRoyaltyVault.NothingToRelease.selector);
        vault.release();
    }

    function test_RejectingCreatorDefersOnlyItsShare() public {
        RejectingPayee badCreator = new RejectingPayee();
        uint256 agentId = _mint(address(badCreator), DEFAULT_CREATOR_BPS);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));
        vm.deal(address(vault), 1_050 ether);
        vault.release();
        assertEq(treasury.balance, 50 ether);
        assertEq(vault.owed(address(0), address(badCreator)), 1_000 ether);
    }

    function test_BlocklistedTokenPayeeDefersERC20Share() public {
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));
        BlocklistToken tok = new BlocklistToken();
        tok.mint(address(vault), 1_050e6);
        tok.setBlocked(treasury, true);
        vault.releaseToken(IERC20(address(tok)));
        assertEq(tok.balanceOf(creator), 1_000e6);
        assertEq(vault.owed(address(tok), treasury), 50e6);
        // Unblocked, the treasury withdraws; others can't take its share.
        tok.setBlocked(treasury, false);
        vm.prank(buyer);
        vm.expectRevert(AgentRoyaltyVault.NothingToRelease.selector);
        vault.withdrawOwed(address(tok), buyer);
        vm.prank(treasury);
        vault.withdrawOwed(address(tok), treasury);
        assertEq(tok.balanceOf(treasury), 50e6);
        assertEq(tok.balanceOf(address(vault)), 0);
    }

    function testFuzz_ReleaseConservesFunds(uint96 amount, bool badTreasury, bool badCreator) public {
        vm.assume(amount > 0);
        address c = badCreator ? address(new RejectingPayee()) : creator;
        uint256 agentId = _mint(c, DEFAULT_CREATOR_BPS);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));
        if (badTreasury) {
            address t = address(new RejectingPayee());
            vm.prank(owner);
            registry.setSecondaryTreasury(t);
        }
        vm.deal(address(vault), amount);
        uint256 before = c.balance + registry.secondaryTreasury().balance;
        vault.release();
        uint256 paid = c.balance + registry.secondaryTreasury().balance - before;
        assertEq(paid + vault.totalOwed(address(0)), amount, "every wei paid or owed");
        assertEq(address(vault).balance, vault.totalOwed(address(0)), "vault holds exactly what it owes");
    }

    function _mint(address to, uint256 royaltyBps) internal returns (uint256 agentId) {
        vm.prank(to);
        agentId = registry.registerAgent("agent", "ipfs://meta", royaltyBps, address(0));
    }
}
