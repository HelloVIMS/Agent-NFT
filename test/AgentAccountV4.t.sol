// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentTBARegistry.sol";
import "../src/AgentAccount.sol";

contract V4Token is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract Burner {
    uint256 public x;
    function burn(uint256 g) external { uint256 s = gasleft(); while (s - gasleft() < g) { x++; } }
}

/// Pays out of the account through a pull it was pre-approved for — the
/// kind of spend balance-delta caps exist to catch.
contract Spender {
    function pay(V4Token t, address to, uint256 a) external { t.transfer(to, a); }
}

/// AgentAccount V4: the guarantees the audit asked for, each pinned.
contract AgentAccountV4Test is Test {
    AgentIdentityRegistry registry;
    AgentTBARegistry tbas;
    AgentAccount account;
    AgentAccount otherAccount;
    V4Token usdc;
    address owner = makeAddr("owner");
    address entryPoint = address(0xEEEE);
    uint256 constant PK = 0xA11CE;
    address signer;

    function setUp() public {
        signer = vm.addr(PK);
        AgentIdentityRegistry impl = new AgentIdentityRegistry();
        registry = AgentIdentityRegistry(address(new ERC1967Proxy(address(impl), abi.encodeCall(AgentIdentityRegistry.initialize, ()))));
        tbas = new AgentTBARegistry(address(registry), entryPoint);
        vm.startPrank(owner);
        uint256 a = registry.registerAgent("A", "uri", 1000, address(0));
        uint256 b = registry.registerAgent("B", "uri", 1000, address(0));
        account = AgentAccount(payable(tbas.createAccount(a, bytes32(0))));
        otherAccount = AgentAccount(payable(tbas.createAccount(b, bytes32(0))));
        vm.stopPrank();
        usdc = new V4Token();
        usdc.mint(address(account), 1_000e6);
        usdc.mint(address(otherAccount), 1_000e6);
        vm.deal(address(account), 10 ether);
    }

    function _key(AgentAccount acct, address[] memory targets, AgentAccount.TokenLimit[] memory limits) internal returns (bytes32) {
        bytes4[] memory sel;
        vm.prank(owner);
        return acct.createSessionKey(signer, targets, sel, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days), limits);
    }

    function _one(address t) internal pure returns (address[] memory a) { a = new address[](1); a[0] = t; }

    function _usdcLimit(uint256 perTx, uint256 total) internal view returns (AgentAccount.TokenLimit[] memory l) {
        l = new AgentAccount.TokenLimit[](1);
        l[0] = AgentAccount.TokenLimit({token: address(usdc), maxPerTx: perTx, maxTotal: total});
    }

    function _sign(AgentAccount acct, bytes32 keyHash, address to, uint256 value, bytes memory data) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", acct.domainSeparator(),
            keccak256(abi.encode(acct.SESSION_CALL_TYPEHASH(), keyHash, to, value, keccak256(data), acct.sessionKeyNonce(keyHash)))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, digest);
        return abi.encodePacked(r, s, v);
    }

    // V3 summed hook gas in storage for the account's whole life and then
    // refused every execute: the deployed Base Sepolia accounts stop after
    // ~13M lifetime gas (fork-tested). V4 accounts it per transaction.
    function test_hookGasIsPerTransactionNotLifetime() public {
        Burner b = new Burner();
        for (uint256 i = 0; i < 60; i++) {
            vm.prank(owner);
            account.execute(address(b), 0, abi.encodeCall(Burner.burn, (500_000)), 0);
        }
        assertGt(b.x(), 0);
    }

    function test_oneCallOverTheGasBoundStillReverts() public {
        Burner b = new Burner();
        vm.prank(owner);
        vm.expectRevert(AgentAccount.HookGasExceeded.selector);
        account.execute{gas: 20_000_000}(address(b), 0, abi.encodeCall(Burner.burn, (13_500_000)), 0);
    }

    function test_entryPointExecutesAfterValidation() public {
        Burner b = new Burner();
        vm.prank(entryPoint);
        account.execute(address(b), 0, abi.encodeCall(Burner.burn, (1_000)), 0);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Invalid signer");
        account.execute(address(b), 0, "", 0);
    }

    // M-02: two keys sharing a signer — a signature for one can't be charged to the other.
    function test_signatureBindsTheKey() public {
        address payee = makeAddr("payee");
        bytes32 k1 = _key(account, _one(payee), new AgentAccount.TokenLimit[](0));
        vm.warp(block.timestamp + 1);
        bytes32 k2 = _key(account, _one(payee), new AgentAccount.TokenLimit[](0));
        bytes memory sigForK1 = _sign(account, k1, payee, 0.1 ether, "");
        vm.expectRevert("Invalid session key signature");
        account.executeWithSessionKey(k2, sigForK1, payee, 0.1 ether, "");
        account.executeWithSessionKey(k1, sigForK1, payee, 0.1 ether, "");
        assertEq(payee.balance, 0.1 ether);
        // Replay of the used signature fails: the key's nonce moved on.
        vm.expectRevert("Invalid session key signature");
        account.executeWithSessionKey(k1, sigForK1, payee, 0.1 ether, "");
    }

    // A signature for one account doesn't work on another account of the same owner.
    function test_signatureBindsTheAccount() public {
        address payee = makeAddr("payee");
        bytes32 k = _key(account, _one(payee), new AgentAccount.TokenLimit[](0));
        vm.deal(address(otherAccount), 1 ether);
        bytes32 kOther = _key(otherAccount, _one(payee), new AgentAccount.TokenLimit[](0));
        assertNotEq(account.domainSeparator(), otherAccount.domainSeparator());
        bytes memory sig = _sign(account, k, payee, 0.1 ether, "");
        vm.expectRevert("Invalid session key signature");
        otherAccount.executeWithSessionKey(kOther, sig, payee, 0.1 ether, "");
    }

    function test_targetsAreRequiredAndNeverThisAccount() public {
        bytes4[] memory sel;
        vm.startPrank(owner);
        vm.expectRevert(AgentAccount.SessionTargetsRequired.selector);
        account.createSessionKey(signer, new address[](0), sel, 1, 1, 0, uint48(block.timestamp + 1), new AgentAccount.TokenLimit[](0));
        vm.expectRevert(abi.encodeWithSelector(AgentAccount.SessionTargetForbidden.selector, address(account)));
        account.createSessionKey(signer, _one(address(account)), sel, 1, 1, 0, uint48(block.timestamp + 1), new AgentAccount.TokenLimit[](0));
        vm.stopPrank();
    }

    // Approvals outlive the key and pulls bypass the caps: never allowed.
    function test_approvalsAndPullsAreForbidden() public {
        bytes32 k = _key(account, _one(address(usdc)), _usdcLimit(10e6, 50e6));
        bytes[4] memory calls = [
            abi.encodeCall(IERC20.approve, (makeAddr("x"), type(uint256).max)),
            abi.encodeWithSelector(0x39509351, makeAddr("x"), 1),
            abi.encodeCall(IERC20.transferFrom, (address(account), makeAddr("x"), 1)),
            abi.encodeWithSelector(0xa22cb465, makeAddr("x"), true)
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            bytes memory sig = _sign(account, k, address(usdc), 0, calls[i]);
            vm.expectRevert(abi.encodeWithSelector(AgentAccount.SessionSelectorForbidden.selector, bytes4(calls[i])));
            account.executeWithSessionKey(k, sig, address(usdc), 0, calls[i]);
        }
    }

    // USDC spend is capped per call and in total, measured as balance change.
    function test_erc20CapsPerTxAndTotal() public {
        address payee = makeAddr("payee");
        bytes32 k = _key(account, _one(address(usdc)), _usdcLimit(10e6, 25e6));
        bytes memory pay10 = abi.encodeCall(IERC20.transfer, (payee, 10e6));
        account.executeWithSessionKey(k, _sign(account, k, address(usdc), 0, pay10), address(usdc), 0, pay10);
        account.executeWithSessionKey(k, _sign(account, k, address(usdc), 0, pay10), address(usdc), 0, pay10);
        assertEq(account.tokenSpent(k, address(usdc)), 20e6);
        bytes memory pay11 = abi.encodeCall(IERC20.transfer, (payee, 11e6));
        bytes memory sig11 = _sign(account, k, address(usdc), 0, pay11);
        vm.expectRevert(abi.encodeWithSelector(AgentAccount.TokenLimitExceeded.selector, address(usdc), 11e6));
        account.executeWithSessionKey(k, sig11, address(usdc), 0, pay11);
        bytes memory sigOver = _sign(account, k, address(usdc), 0, pay10);
        vm.expectRevert(abi.encodeWithSelector(AgentAccount.TokenLimitExceeded.selector, address(usdc), 10e6));
        account.executeWithSessionKey(k, sigOver, address(usdc), 0, pay10);
        assertEq(usdc.balanceOf(payee), 20e6);
    }

    // The cap sees spend through any path — here an allowed contract that
    // the owner pre-approved pulls from the account.
    function test_capsSeeIndirectSpend() public {
        Spender sp = new Spender();
        vm.prank(owner);
        account.execute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (address(sp), 0)), 0);
        // The account itself funds the spender's transfer by sending first.
        bytes32 k = _key(account, _one(address(usdc)), _usdcLimit(5e6, 5e6));
        bytes memory send = abi.encodeCall(IERC20.transfer, (address(sp), 6e6));
        bytes memory sig = _sign(account, k, address(usdc), 0, send);
        vm.expectRevert(abi.encodeWithSelector(AgentAccount.TokenLimitExceeded.selector, address(usdc), 6e6));
        account.executeWithSessionKey(k, sig, address(usdc), 0, send);
    }

    function testFuzz_capNeverExceeded(uint64[6] memory amounts) public {
        address payee = makeAddr("payee");
        uint256 perTx = 30e6;
        uint256 total = 100e6;
        bytes32 k = _key(account, _one(address(usdc)), _usdcLimit(perTx, total));
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 a = uint256(amounts[i]) % 40e6;
            bytes memory pay = abi.encodeCall(IERC20.transfer, (payee, a));
            bytes memory sig = _sign(account, k, address(usdc), 0, pay);
            try account.executeWithSessionKey(k, sig, address(usdc), 0, pay) {} catch {}
        }
        assertLe(usdc.balanceOf(payee), total);
        assertEq(usdc.balanceOf(payee), account.tokenSpent(k, address(usdc)));
    }
}
