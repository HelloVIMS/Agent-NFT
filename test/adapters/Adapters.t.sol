// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentReputationERC8004Adapter, ILegacyReputationRegistry} from "../../src/adapters/AgentReputationERC8004Adapter.sol";
import {IdentityTipBeneficiaryResolver, IIdentityRegistryView}    from "../../src/adapters/IdentityTipBeneficiaryResolver.sol";

/// @dev Mock the legacy registry surface (mirrors AgentReputationRegistry's
///      tuple-returning storage layout for `feedbacks(agentId, idx)`).
contract MockLegacyReg is ILegacyReputationRegistry {
    struct FB {
        address client; int128 value; uint8 decimals;
        string tag1; string tag2; string uri;
        uint256 ts; bool revoked;
    }
    mapping(uint256 => FB[]) public fbs;
    mapping(uint256 => mapping(address => bool)) internal _has;

    function add(uint256 a, FB calldata f) external {
        fbs[a].push(f);
        _has[a][f.client] = true;
    }
    function getFeedbackCount(uint256 a) external view returns (uint256) { return fbs[a].length; }
    function getFeedbackAt(uint256 a, uint256 i) external view returns (
        address, int128, uint8, string memory, string memory, string memory, uint256, bool
    ) {
        FB storage f = fbs[a][i];
        return (f.client, f.value, f.decimals, f.tag1, f.tag2, f.uri, f.ts, f.revoked);
    }
}

/// @dev Mock the identity registry surface used by the tip resolver.
contract MockIdentity is IIdentityRegistryView {
    struct A { string name; address tba; uint256 createdAt; bool active; }
    mapping(uint256 => A) internal _agents;
    mapping(uint256 => address) internal _owner;

    function setAgent(uint256 id, address holder, address tba, bool active) external {
        _agents[id] = A({ name: "", tba: tba, createdAt: 1, active: active });
        _owner[id] = holder;
    }
    function agents(uint256 id) external view returns (string memory, address, uint256, bool, address) {
        A storage a = _agents[id];
        return (a.name, a.tba, a.createdAt, a.active, address(0));
    }
    function ownerOf(uint256 id) external view returns (address) {
        address o = _owner[id];
        require(o != address(0), "nonexistent");
        return o;
    }
}

contract AdaptersTest is Test {
    address constant ALICE = address(0xA11CE);
    address constant BOB   = address(0xB0B);
    address constant CARL  = address(0xCA21);

    // ─────────────────────────────────────────────────────────────────────
    // AgentReputationERC8004Adapter
    // ─────────────────────────────────────────────────────────────────────

    function test_adapter_emptyClientsReverts() public {
        MockLegacyReg reg = new MockLegacyReg();
        AgentReputationERC8004Adapter ad = new AgentReputationERC8004Adapter(address(reg), 0);
        address[] memory none = new address[](0);
        vm.expectRevert(AgentReputationERC8004Adapter.EmptyClientAddresses.selector);
        ad.getSummary(1, none, "", "");
    }

    function test_adapter_filtersByClientAddress() public {
        MockLegacyReg reg = new MockLegacyReg();
        AgentReputationERC8004Adapter ad = new AgentReputationERC8004Adapter(address(reg), 0);

        reg.add(1, MockLegacyReg.FB({client: ALICE, value:  80, decimals: 0, tag1: "", tag2: "", uri: "", ts: 1, revoked: false}));
        reg.add(1, MockLegacyReg.FB({client: BOB,   value:  20, decimals: 0, tag1: "", tag2: "", uri: "", ts: 1, revoked: false}));
        reg.add(1, MockLegacyReg.FB({client: CARL,  value: -50, decimals: 0, tag1: "", tag2: "", uri: "", ts: 1, revoked: false}));

        // Trust only Alice and Bob → average = 50.
        address[] memory trusted = new address[](2);
        trusted[0] = ALICE; trusted[1] = BOB;
        (uint64 count, int128 v, uint8 dec) = ad.getSummary(1, trusted, "", "");
        assertEq(count, 2);
        assertEq(v, int128(50));
        assertEq(dec, 0);

        // Trust only Carl → average = -50.
        address[] memory carl = new address[](1); carl[0] = CARL;
        (count, v,) = ad.getSummary(1, carl, "", "");
        assertEq(count, 1); assertEq(v, int128(-50));
    }

    function test_adapter_filtersByTag() public {
        MockLegacyReg reg = new MockLegacyReg();
        AgentReputationERC8004Adapter ad = new AgentReputationERC8004Adapter(address(reg), 0);

        reg.add(1, MockLegacyReg.FB({client: ALICE, value: 100, decimals: 0, tag1: "speed",   tag2: "", uri: "", ts: 1, revoked: false}));
        reg.add(1, MockLegacyReg.FB({client: ALICE, value:  10, decimals: 0, tag1: "quality", tag2: "", uri: "", ts: 1, revoked: false}));
        address[] memory t = new address[](1); t[0] = ALICE;

        (uint64 c, int128 v,) = ad.getSummary(1, t, "speed", "");
        assertEq(c, 1); assertEq(v, int128(100));

        (c, v,) = ad.getSummary(1, t, "quality", "");
        assertEq(c, 1); assertEq(v, int128(10));

        // No tag filter → both.
        (c, v,) = ad.getSummary(1, t, "", "");
        assertEq(c, 2); assertEq(v, int128(55));
    }

    function test_adapter_skipsRevoked() public {
        MockLegacyReg reg = new MockLegacyReg();
        AgentReputationERC8004Adapter ad = new AgentReputationERC8004Adapter(address(reg), 0);
        reg.add(1, MockLegacyReg.FB({client: ALICE, value:  80, decimals: 0, tag1: "", tag2: "", uri: "", ts: 1, revoked: true}));
        reg.add(1, MockLegacyReg.FB({client: ALICE, value:  20, decimals: 0, tag1: "", tag2: "", uri: "", ts: 1, revoked: false}));
        address[] memory t = new address[](1); t[0] = ALICE;
        (uint64 c, int128 v,) = ad.getSummary(1, t, "", "");
        assertEq(c, 1); assertEq(v, int128(20));
    }

    function test_adapter_rescalesDecimals() public {
        MockLegacyReg reg = new MockLegacyReg();
        // Adapter normalises to 2 decimal places.
        AgentReputationERC8004Adapter ad = new AgentReputationERC8004Adapter(address(reg), 2);
        // Alice gives 9977 with 4 decimals → scaled-to-2 = 99
        // Bob   gives  1   with 0 decimals → scaled-to-2 = 100
        reg.add(1, MockLegacyReg.FB({client: ALICE, value: 9977, decimals: 4, tag1: "", tag2: "", uri: "", ts: 1, revoked: false}));
        reg.add(1, MockLegacyReg.FB({client: BOB,   value:    1, decimals: 0, tag1: "", tag2: "", uri: "", ts: 1, revoked: false}));
        address[] memory t = new address[](2); t[0] = ALICE; t[1] = BOB;
        (uint64 c, int128 v, uint8 dec) = ad.getSummary(1, t, "", "");
        assertEq(c, 2); assertEq(dec, 2);
        // (99 + 100) / 2 = 99 (integer division)
        assertEq(v, int128(99));
    }

    // ─────────────────────────────────────────────────────────────────────
    // IdentityTipBeneficiaryResolver
    // ─────────────────────────────────────────────────────────────────────

    function test_resolver_zeroRegistryReverts() public {
        vm.expectRevert(IdentityTipBeneficiaryResolver.ZeroRegistry.selector);
        new IdentityTipBeneficiaryResolver(address(0));
    }

    function test_resolver_returnsTBAWhenSet() public {
        MockIdentity id = new MockIdentity();
        id.setAgent(1, ALICE, address(0xBADBADBA), true);
        IdentityTipBeneficiaryResolver r = new IdentityTipBeneficiaryResolver(address(id));
        assertEq(r.tipBeneficiary(1), address(0xBADBADBA));
    }

    function test_resolver_fallsBackToHolderWhenNoTBA() public {
        MockIdentity id = new MockIdentity();
        id.setAgent(1, ALICE, address(0), true);
        IdentityTipBeneficiaryResolver r = new IdentityTipBeneficiaryResolver(address(id));
        assertEq(r.tipBeneficiary(1), ALICE);
    }

    function test_resolver_inactiveAgentReturnsZero() public {
        MockIdentity id = new MockIdentity();
        id.setAgent(1, ALICE, address(0xBADBADBA), false);
        IdentityTipBeneficiaryResolver r = new IdentityTipBeneficiaryResolver(address(id));
        assertEq(r.tipBeneficiary(1), address(0));
    }

    function test_resolver_nonexistentAgentReverts() public {
        MockIdentity id = new MockIdentity();
        IdentityTipBeneficiaryResolver r = new IdentityTipBeneficiaryResolver(address(id));
        vm.expectRevert();
        r.tipBeneficiary(999);
    }
}
