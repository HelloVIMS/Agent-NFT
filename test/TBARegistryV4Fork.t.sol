// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../script/DeployTBARegistryV4.s.sol";
import "../src/AgentAccount.sol";

interface IIdentityMint {
    function mintWithFullStack(string calldata, string calldata, uint256, address, bytes32, bytes32, address, uint256) external returns (uint256, address);
    function getAgent(uint256) external view returns (string memory, address, uint256, bool, address, address);
}

contract Burner { uint256 public x; function burn(uint256 g) external { uint256 s = gasleft(); while (s - gasleft() < g) { x++; } } }

/// Rehearses the V4 TBA registry switch against live Base Sepolia
/// (VIMS_TEST_BASE_SEPOLIA_FORK=1): a new agent gets a V4 account that keeps
/// executing past V3's lifetime-gas limit; an existing agent's TBA is
/// untouched.
contract TBARegistryV4ForkTest is Test {
    address constant IDENTITY = 0xfE1ef66Ba95891d3cDf6FB83FE1444Bc3bB9FEeF;
    address constant ENTRYPOINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant OWNER = 0xE48840eD6678218Bd21dF2671b98bCF23de661b9;

    function test_newAgentsGetV4Accounts() public {
        if (!vm.envOr("VIMS_TEST_BASE_SEPOLIA_FORK", false)) return;
        vm.createSelectFork("https://sepolia.base.org");
        (, address oldTba,,,,) = IIdentityMint(IDENTITY).getAgent(241);

        // DeployTBARegistryV4's two steps, with the identity owner as caller
        // (under broadcast the script's calls come from the deployer EOA).
        vm.startPrank(OWNER);
        AgentTBARegistry tba = new AgentTBARegistry(IDENTITY, ENTRYPOINT);
        IIdentityTBA(IDENTITY).setTrustedTBARegistry(address(tba));
        vm.stopPrank();

        address minter = makeAddr("minter");
        vm.prank(minter);
        (uint256 id, address acct) = IIdentityMint(IDENTITY).mintWithFullStack("V4 agent", "ipfs://x", 500, address(0), bytes32(0), bytes32(0), address(0), 0);
        (, address bound,,,,) = IIdentityMint(IDENTITY).getAgent(id);
        assertEq(bound, acct, "bound TBA is the created account");
        assertEq(AgentAccount(payable(acct)).SESSION_CALL_TYPEHASH(), keccak256("SessionCall(bytes32 keyHash,address to,uint256 value,bytes data,uint256 nonce)"));

        Burner b = new Burner();
        for (uint256 i = 0; i < 40; i++) {
            vm.prank(minter);
            AgentAccount(payable(acct)).execute(address(b), 0, abi.encodeCall(Burner.burn, (500_000)), 0);
        }
        (, address stillOld,,,,) = IIdentityMint(IDENTITY).getAgent(241);
        assertEq(stillOld, oldTba, "existing agents keep their TBA");
    }
}
