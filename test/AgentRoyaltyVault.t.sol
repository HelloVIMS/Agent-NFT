// SPDX-License-Identifier: MIT
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

        vm.prank(address(this));
        registry.transferOwnership(owner);

        vm.prank(owner);
        registry.initializeV7(treasury);
    }

    // ============ State / config ============

    function test_V7Initialized() public view {
        assertEq(registry.secondaryTreasury(), treasury);
        assertEq(registry.secondarySystemFeeBps(), DEFAULT_SYSTEM_BPS);
    }

    function test_V7InitializerCannotBeCalledTwice() public {
        vm.prank(owner);
        vm.expectRevert(); // Initializable: InvalidInitialization
        registry.initializeV7(treasury);
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

    function test_SetSecondarySystemFeeBpsCappedAt500() public {
        vm.prank(owner);
        vm.expectRevert(AgentIdentityRegistry.InvalidValue.selector);
        registry.setSecondarySystemFeeBps(501);

        vm.prank(owner);
        registry.setSecondarySystemFeeBps(500);
        assertEq(registry.secondarySystemFeeBps(), 500);
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

        // (1000 + 50) / 10000 * 10000 ether = 1050 ether
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

        // Buyer pays the *combined* royalty amount (1050 of every 10000 sale).
        uint256 totalRoyalty = 1_050 ether;
        vm.deal(buyer, totalRoyalty);
        vm.prank(buyer);
        (bool ok,) = address(vault).call{value: totalRoyalty}("");
        assertTrue(ok);

        uint256 creatorBefore  = creator.balance;
        uint256 treasuryBefore = treasury.balance;

        vault.release();

        // Of 1050 wei, treasury gets 50/1050 share = 50 ether, creator gets 1000 ether.
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

    function test_ReleaseUsesLiveBpsAfterCreatorUpdate() public {
        uint256 agentId = _mint(creator, DEFAULT_CREATOR_BPS);
        AgentRoyaltyVault vault = AgentRoyaltyVault(payable(registry.deployRoyaltyVault(agentId)));

        // Creator bumps their bps from 10% -> 25% post-deploy.
        vm.prank(creator);
        registry.updateCreatorRoyalty(agentId, 2500);

        // Now royaltyInfo: 2500 + 50 = 2550 bps.
        (, uint256 amount) = registry.royaltyInfo(agentId, 10_000 ether);
        assertEq(amount, 2_550 ether);

        vm.deal(buyer, 2_550 ether);
        vm.prank(buyer);
        (bool ok,) = address(vault).call{value: 2_550 ether}("");
        assertTrue(ok);

        vault.release();

        // treasury: 50/2550 of 2550 = 50 ether. creator: rest.
        assertEq(treasury.balance, 50 ether);
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

    function test_UpdateCreatorRoyaltyToZero() public {
        uint256 agentId = _mint(creator, 1000);

        vm.prank(creator);
        registry.updateCreatorRoyalty(agentId, 0);

        (, uint256 bps) = registry.getCreatorRoyalty(agentId);
        assertEq(bps, 0);
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
        assertEq(amount, (uint256(salePrice) * (creatorBps + 50)) / 10_000);
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

    function _mint(address to, uint256 royaltyBps) internal returns (uint256 agentId) {
        vm.prank(to);
        agentId = registry.registerAgentWithRoyalty("agent", "ipfs://meta", royaltyBps);
    }
}
