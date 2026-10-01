// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title AgentAccount
 * @notice ERC-6551 Token Bound Account for Agent agents with ERC-4337 support
 * @dev V4: hook gas is accounted per outermost call (V3 summed it in storage
 *      forever, so an account stopped executing for good after ~13M
 *      lifetime gas); ERC-4337 calls execute through the EntryPoint;
 *      session keys sign EIP-712 over this account and their own keyHash,
 *      name explicit targets, can't approve or pull, and spend ERC20s only
 *      within per-token caps.
 */
import {VimsProvenance} from "./VimsProvenance.sol";

contract AgentAccount is IERC165, IERC721Receiver, IERC1155Receiver, IERC1271, ReentrancyGuard, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentAccount";
    }

    uint256 public state;
    
    // ERC-4337 EntryPoint
    address public immutable entryPoint;
    
    // Hook safety constants
    uint8 public constant MAX_HOOK_DEPTH = 8;
    uint256 public constant MAX_HOOK_GAS = 13_000_000;
    
    // Hook-call depth lives in transient storage (EIP-1153): it never
    // outlives the transaction. Gas is bounded per outermost call.
    bytes32 private constant _DEPTH_SLOT = keccak256("vims.agentaccount.hook.depth");
    
    // Epoch for bulk session key revocation
    uint256 public sessionKeyEpoch;
    
    /// @notice What a session key signs: one call, from this account (the
    ///         domain's verifyingContract), charged to exactly this key.
    bytes32 public constant SESSION_CALL_TYPEHASH = keccak256(
        "SessionCall(bytes32 keyHash,address to,uint256 value,bytes data,uint256 nonce)"
    );

    /// @notice An ERC20 a session key may spend, measured as the account's
    ///         balance drop across each call.
    struct TokenLimit {
        address token;
        uint256 maxPerTx;
        uint256 maxTotal;
    }
    
    // Session key storage
    struct SessionKey {
        address signer;
        address[] allowedTargets;
        bytes4[] allowedSelectors;
        uint256 maxValuePerTx;
        uint256 maxTotalValue;
        uint256 usedValue;
        uint48 validAfter;
        uint48 validUntil;
        uint256 epoch;
        bool revoked;
    }
    
    mapping(bytes32 => SessionKey) public sessionKeys;
    bytes32[] public sessionKeyHashes;
    /// @notice Per-key nonce: each key's signatures are ordered on their own,
    ///         so the owner's executes don't invalidate them.
    mapping(bytes32 => uint256) public sessionKeyNonce;
    mapping(bytes32 => TokenLimit[]) internal _tokenLimits;
    mapping(bytes32 => mapping(address => uint256)) public tokenSpent;
    
    // ERC-4337 UserOperation struct (packed)
    struct PackedUserOperation {
        address sender;
        uint256 nonce;
        bytes initCode;
        bytes callData;
        bytes32 accountGasLimits;
        uint256 preVerificationGas;
        bytes32 gasFees;
        bytes paymasterAndData;
        bytes signature;
    }
    
    event SessionKeyCreated(
        bytes32 indexed keyHash,
        address indexed signer,
        uint48 validUntil
    );
    
    event SessionKeyRevoked(bytes32 indexed keyHash);
    event AllSessionKeysRevoked(uint256 indexed newEpoch);
    
    event Executed(
        address indexed target,
        uint256 value,
        bytes data,
        uint256 newState
    );
    
    error HookDepthExceeded();
    error HookGasExceeded();
    error InvalidEntryPoint();
    error InvalidSignature();
    error SessionTargetsRequired();
    error SessionTargetForbidden(address target);
    error SessionSelectorForbidden(bytes4 selector);
    error TokenLimitExceeded(address token, uint256 spent);
    
    constructor(address _entryPoint) {
        entryPoint = _entryPoint;
    }

    /// @notice EIP-712 domain of this account. Computed at call time: each
    ///         account is a clone of one implementation, and an immutable
    ///         would carry the implementation's address, letting a
    ///         signature for one account replay on every other.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("AgentAccount"),
            keccak256("4"),
            block.chainid,
            address(this)
        ));
    }
    
    receive() external payable {}
    
    // ============ Modifiers ============
    
    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert InvalidEntryPoint();
        _;
    }
    
    modifier hookSafe() {
        uint256 depth = _tload(_DEPTH_SLOT);
        if (depth >= MAX_HOOK_DEPTH) revert HookDepthExceeded();
        uint256 gasStart = gasleft();
        _tstore(_DEPTH_SLOT, depth + 1);
        _;
        _tstore(_DEPTH_SLOT, depth);
        // The outermost call's gas includes every nested (hook) call.
        if (depth == 0 && gasStart - gasleft() > MAX_HOOK_GAS) revert HookGasExceeded();
    }

    function _tload(bytes32 slot) private view returns (uint256 v) {
        assembly { v := tload(slot) }
    }

    function _tstore(bytes32 slot, uint256 v) private {
        assembly { tstore(slot, v) }
    }
    
    // ============ ERC-4337 IAccount ============
    
    /**
     * @notice Validate a UserOperation (ERC-4337)
     * @param userOp The user operation to validate
     * @param userOpHash Hash of the user operation
     * @param missingAccountFunds Funds missing from the account to pay for the operation
     * @return validationData 0 if valid, 1 if invalid, or packed validAfter/validUntil
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        // Validate signature
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        address recovered = ECDSA.recover(ethSignedHash, userOp.signature);
        
        if (!_isValidSigner(recovered)) {
            return 1; // Invalid signature
        }
        
        // Pay prefund if needed
        if (missingAccountFunds > 0) {
            (bool success,) = payable(entryPoint).call{value: missingAccountFunds}("");
            (success); // Ignore result, entryPoint will revert if not enough
        }
        
        return 0; // Valid
    }
    
    /**
     * @notice Execute from EntryPoint (ERC-4337)
     */
    function executeUserOp(
        PackedUserOperation calldata,
        bytes32
    ) external onlyEntryPoint {
        // Execution is done via callData in the UserOp
        // This function is called after validateUserOp succeeds
    }
    
    // ============ ERC-1271 Signature Validation ============
    
    /**
     * @notice Validate a signature (ERC-1271)
     * @param hash The hash that was signed
     * @param signature The signature to validate
     * @return magicValue 0x1626ba7e if valid, 0xffffffff if invalid
     */
    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4 magicValue) {
        // Try to recover signer from signature
        address recovered = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(hash), signature);
        
        if (_isValidSigner(recovered)) {
            return 0x1626ba7e; // ERC-1271 magic value
        }
        
        // Also check if owner is a smart contract that can validate
        address _owner = owner();
        if (_owner.code.length > 0) {
            try IERC1271(_owner).isValidSignature(hash, signature) returns (bytes4 result) {
                return result;
            } catch {
                return 0xffffffff;
            }
        }
        
        return 0xffffffff; // Invalid
    }
    
    // ============ Core Execution ============
    
    /**
     * @notice Execute a call from this account
     * @param to Target address
     * @param value ETH value to send
     * @param data Calldata
     * @param operation Must be 0 (call)
     */
    function execute(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external payable nonReentrant hookSafe returns (bytes memory result) {
        // The EntryPoint calls in after validateUserOp checked the owner's
        // signature on the UserOperation.
        require(msg.sender == entryPoint || _isValidSigner(msg.sender), "Invalid signer");
        require(operation == 0, "Only call operations supported");
        
        ++state;
        
        bool success;
        (success, result) = to.call{value: value}(data);
        
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        
        emit Executed(to, value, data, state);
    }
    
    /**
     * @notice Execute a call using a session key
     * @param keyHash The session key hash
     * @param signature Signature from the session key signer
     * @param to Target address
     * @param value ETH value
     * @param data Calldata
     */
    function executeWithSessionKey(
        bytes32 keyHash,
        bytes calldata signature,
        address to,
        uint256 value,
        bytes calldata data
    ) external payable nonReentrant hookSafe returns (bytes memory result) {
        SessionKey storage key = sessionKeys[keyHash];
        
        require(key.signer != address(0), "Unknown session key");
        require(!key.revoked, "Session key revoked");
        require(key.epoch == sessionKeyEpoch, "Session key epoch invalidated");
        require(block.timestamp >= key.validAfter, "Session key not yet valid");
        require(block.timestamp <= key.validUntil, "Session key expired");
        require(value <= key.maxValuePerTx, "Exceeds per-tx value limit");
        require(key.usedValue + value <= key.maxTotalValue, "Exceeds total value limit");
        
        // EIP-712 over this account's domain, binding the key itself (a
        // signature can't be charged to another key of the same signer) and
        // the key's own nonce (no replay). abi.encode + keccak256(data)
        // keep dynamic fields unambiguous.
        uint256 nonce = sessionKeyNonce[keyHash];
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            domainSeparator(),
            keccak256(abi.encode(SESSION_CALL_TYPEHASH, keyHash, to, value, keccak256(data), nonce))
        ));
        require(
            SignatureChecker.isValidSignatureNow(key.signer, digest, signature),
            "Invalid session key signature"
        );
        
        _checkSessionCall(key, to, data);
        
        key.usedValue += value;
        sessionKeyNonce[keyHash] = nonce + 1;
        ++state;

        TokenLimit[] storage limits = _tokenLimits[keyHash];
        uint256[] memory before = new uint256[](limits.length);
        for (uint256 i = 0; i < limits.length; i++) {
            before[i] = _balanceOf(limits[i].token);
        }
        
        bool success;
        (success, result) = to.call{value: value}(data);
        
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }

        for (uint256 i = 0; i < limits.length; i++) {
            uint256 afterBal = _balanceOf(limits[i].token);
            if (afterBal >= before[i]) continue;
            uint256 spent = before[i] - afterBal;
            uint256 total = tokenSpent[keyHash][limits[i].token] + spent;
            if (spent > limits[i].maxPerTx || total > limits[i].maxTotal) revert TokenLimitExceeded(limits[i].token, spent);
            tokenSpent[keyHash][limits[i].token] = total;
        }
        
        emit Executed(to, value, data, state);
    }

    /// @dev A session key reaches only the targets it names, never this
    ///      account, and never a selector that hands out or pulls assets:
    ///      approvals outlive the key, and pulls move value the caps can't see.
    function _checkSessionCall(SessionKey storage key, address to, bytes calldata data) internal view {
        if (to == address(this)) revert SessionTargetForbidden(to);
        require(_isAllowedTarget(key, to), "Target not allowed");
        if (data.length >= 4) {
            bytes4 selector = bytes4(data[:4]);
            if (
                selector == 0x095ea7b3 || // approve(address,uint256)
                selector == 0x39509351 || // increaseAllowance(address,uint256)
                selector == 0xa22cb465 || // setApprovalForAll(address,bool)
                selector == 0x23b872dd || // transferFrom(address,address,uint256)
                selector == 0x42842e0e || // safeTransferFrom(address,address,uint256)
                selector == 0xb88d4fde || // safeTransferFrom(address,address,uint256,bytes)
                selector == 0xf242432a || // safeTransferFrom(address,address,uint256,uint256,bytes)
                selector == 0x2eb2c2d6 || // safeBatchTransferFrom(...)
                selector == 0xd505accf    // permit(...)
            ) revert SessionSelectorForbidden(selector);
            require(_isAllowedSelector(key, selector), "Selector not allowed");
        }
    }

    function _balanceOf(address erc20) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = erc20.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (ok && ret.length >= 32) bal = abi.decode(ret, (uint256));
    }
    
    /**
     * @notice Create a new session key
     */
    function createSessionKey(
        address signer,
        address[] calldata allowedTargets,
        bytes4[] calldata allowedSelectors,
        uint256 maxValuePerTx,
        uint256 maxTotalValue,
        uint48 validAfter,
        uint48 validUntil,
        TokenLimit[] calldata tokenLimits
    ) external returns (bytes32 keyHash) {
        require(_isValidSigner(msg.sender), "Only owner can create session keys");
        require(validUntil > validAfter, "Invalid validity period");
        require(signer != address(0), "Invalid signer");
        // "Everything" is never a session key's scope.
        if (allowedTargets.length == 0) revert SessionTargetsRequired();
        for (uint256 i = 0; i < allowedTargets.length; i++) {
            if (allowedTargets[i] == address(this) || allowedTargets[i] == address(0)) revert SessionTargetForbidden(allowedTargets[i]);
        }
        
        keyHash = keccak256(abi.encodePacked(
            address(this),
            signer,
            block.timestamp,
            sessionKeyHashes.length
        ));
        
        sessionKeys[keyHash] = SessionKey({
            signer: signer,
            allowedTargets: allowedTargets,
            allowedSelectors: allowedSelectors,
            maxValuePerTx: maxValuePerTx,
            maxTotalValue: maxTotalValue,
            usedValue: 0,
            validAfter: validAfter,
            validUntil: validUntil,
            epoch: sessionKeyEpoch,
            revoked: false
        });
        
        for (uint256 i = 0; i < tokenLimits.length; i++) {
            require(tokenLimits[i].token != address(0) && tokenLimits[i].maxPerTx <= tokenLimits[i].maxTotal, "Invalid token limit");
            _tokenLimits[keyHash].push(tokenLimits[i]);
        }
        sessionKeyHashes.push(keyHash);
        
        emit SessionKeyCreated(keyHash, signer, validUntil);
    }
    
    /**
     * @notice Revoke a session key
     */
    function revokeSessionKey(bytes32 keyHash) external {
        require(_isValidSigner(msg.sender), "Only owner can revoke session keys");
        require(!sessionKeys[keyHash].revoked, "Already revoked");
        
        sessionKeys[keyHash].revoked = true;
        
        emit SessionKeyRevoked(keyHash);
    }
    
    /**
     * @notice Revoke all session keys by incrementing the epoch
     */
    function revokeAllSessionKeys() external {
        require(_isValidSigner(msg.sender), "Only owner can revoke session keys");
        
        ++sessionKeyEpoch;
        
        emit AllSessionKeysRevoked(sessionKeyEpoch);
    }
    
    /**
     * @notice Get all session key hashes
     */
    function getSessionKeyHashes() external view returns (bytes32[] memory) {
        return sessionKeyHashes;
    }
    
    /**
     * @notice Get session key details
     */
    function getSessionKey(bytes32 keyHash) external view returns (
        address signer,
        uint256 maxValuePerTx,
        uint256 maxTotalValue,
        uint256 usedValue,
        uint48 validAfter,
        uint48 validUntil,
        bool revoked
    ) {
        SessionKey storage key = sessionKeys[keyHash];
        return (
            key.signer,
            key.maxValuePerTx,
            key.maxTotalValue,
            key.usedValue,
            key.validAfter,
            key.validUntil,
            key.revoked
        );
    }
    
    /// @notice The ERC20 caps of a session key.
    function getSessionKeyTokenLimits(bytes32 keyHash) external view returns (TokenLimit[] memory) {
        return _tokenLimits[keyHash];
    }

    /**
     * @notice Returns the owner of the NFT that owns this account
     */
    function owner() public view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        
        if (chainId != block.chainid) return address(0);
        
        return IERC721(tokenContract).ownerOf(tokenId);
    }
    
    /**
     * @notice Returns the token that owns this account
     */
    function token() public view returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        bytes memory footer = new bytes(0x60);
        
        // ERC-1167 minimal proxy is 45 bytes (0x2d), immutable args follow
        assembly {
            extcodecopy(address(), add(footer, 0x20), 0x2d, 0x60)
        }
        
        return abi.decode(footer, (uint256, address, uint256));
    }
    
    /**
     * @notice Check if a signer is valid (owner of the NFT)
     */
    function _isValidSigner(address signer) internal view returns (bool) {
        return signer == owner();
    }
    
    function _isAllowedTarget(SessionKey storage key, address target) internal view returns (bool) {
        for (uint256 i = 0; i < key.allowedTargets.length; i++) {
            if (key.allowedTargets[i] == target) return true;
        }
        return false;
    }
    
    function _isAllowedSelector(SessionKey storage key, bytes4 selector) internal view returns (bool) {
        if (key.allowedSelectors.length == 0) return true; // Empty = all allowed
        
        for (uint256 i = 0; i < key.allowedSelectors.length; i++) {
            if (key.allowedSelectors[i] == selector) return true;
        }
        return false;
    }
    
    // ERC-165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId ||
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(IERC1271).interfaceId ||
            interfaceId == 0x3a871cdd; // IAccount.validateUserOp selector
    }
    
    // ERC-721 Receiver
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    
    // ERC-1155 Receiver
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }
    
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }
}
