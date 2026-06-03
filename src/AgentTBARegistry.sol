// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Create2.sol";
import "./AgentAccount.sol";
import "./interfaces/IAgentIdentityRegistry.sol";

/**
 * @title AgentTBARegistry
 * @notice Registry and factory for creating Token Bound Accounts for Agents
 * @dev Compatible with ERC-6551 standard
 * @dev V2: Linked to AgentIdentityRegistry for validation and auto-registration
 */
import {VimsProvenance} from "./VimsProvenance.sol";

contract AgentTBARegistry is VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentTBARegistry";
    }

    address public immutable implementation;
    address public immutable identityRegistry;
    address public immutable entryPoint;
    
    event AccountCreated(
        address indexed account,
        address indexed implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    );
    
    error InvalidToken();
    error TBAAlreadyExists();
    
    constructor(address _identityRegistry, address _entryPoint) {
        require(_identityRegistry != address(0), "Invalid registry");
        require(_entryPoint != address(0), "Invalid entry point");
        identityRegistry = _identityRegistry;
        entryPoint = _entryPoint;
        // Deploy the account implementation
        implementation = address(new AgentAccount(_entryPoint));
    }
    
    /**
     * @notice Create a Token Bound Account for a Agent NFT
     * @dev Only creates TBAs for valid Agent tokens from the linked IdentityRegistry
     * @param tokenId The Agent token ID
     * @param salt Additional salt for address derivation
     * @return account The created account address
     */
    function createAccount(
        uint256 tokenId,
        bytes32 salt
    ) external returns (address account) {
        // Validate token exists in our identity registry
        address tokenOwner;
        try IAgentIdentityRegistry(identityRegistry).ownerOf(tokenId) returns (address _owner) {
            tokenOwner = _owner;
        } catch {
            revert InvalidToken();
        }
        if (tokenOwner == address(0)) revert InvalidToken();
        
        // Check if TBA already deployed
        address existingAccount = _account(
            implementation,
            salt,
            block.chainid,
            identityRegistry,
            tokenId
        );
        if (existingAccount.code.length > 0) revert TBAAlreadyExists();
        
        account = _createAccount(
            implementation,
            salt,
            block.chainid,
            identityRegistry,
            tokenId
        );
        
        // Auto-register TBA address back to identity registry
        // Note: This will only work if called by token owner (registry checks ownership)
        // If caller is not owner, they can manually call setTBAAddress later
        try IAgentIdentityRegistry(identityRegistry).setTBAAddress(tokenId, account) {
            // Successfully registered
        } catch {
            // Caller not owner - TBA still created, just not auto-registered
        }
        
        emit AccountCreated(
            account,
            implementation,
            salt,
            block.chainid,
            identityRegistry,
            tokenId
        );
    }
    
    /**
     * @notice Create a Token Bound Account with explicit token contract (legacy compatibility)
     * @param tokenContract The token contract address (must match identityRegistry)
     * @param tokenId The Agent token ID
     * @param salt Additional salt for address derivation
     * @return account The created account address
     */
    function createAccountLegacy(
        address tokenContract,
        uint256 tokenId,
        bytes32 salt
    ) external returns (address account) {
        require(tokenContract == identityRegistry, "Must use linked registry");
        
        account = _createAccount(
            implementation,
            salt,
            block.chainid,
            tokenContract,
            tokenId
        );
        
        emit AccountCreated(
            account,
            implementation,
            salt,
            block.chainid,
            tokenContract,
            tokenId
        );
    }
    
    /**
     * @notice Compute the address of a Token Bound Account
     * @param tokenContract The Agent Identity Registry address
     * @param tokenId The Agent token ID
     * @param salt Additional salt for address derivation
     * @return The computed account address
     */
    function account(
        address tokenContract,
        uint256 tokenId,
        bytes32 salt
    ) external view returns (address) {
        return _account(
            implementation,
            salt,
            block.chainid,
            tokenContract,
            tokenId
        );
    }
    
    /**
     * @notice Check if an account has been deployed
     */
    function isAccountDeployed(
        address tokenContract,
        uint256 tokenId,
        bytes32 salt
    ) external view returns (bool) {
        address accountAddress = _account(
            implementation,
            salt,
            block.chainid,
            tokenContract,
            tokenId
        );
        
        return accountAddress.code.length > 0;
    }
    
    function _createAccount(
        address _implementation,
        bytes32 _salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) internal returns (address) {
        bytes memory code = _creationCode(
            _implementation,
            chainId,
            tokenContract,
            tokenId
        );
        
        bytes32 salt = keccak256(abi.encodePacked(_salt, chainId, tokenContract, tokenId));
        
        address _account = Create2.computeAddress(salt, keccak256(code));
        
        if (_account.code.length != 0) return _account;
        
        _account = Create2.deploy(0, salt, code);
        
        return _account;
    }
    
    function _account(
        address _implementation,
        bytes32 _salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_salt, chainId, tokenContract, tokenId));
        
        bytes32 bytecodeHash = keccak256(
            _creationCode(_implementation, chainId, tokenContract, tokenId)
        );
        
        return Create2.computeAddress(salt, bytecodeHash);
    }
    
    function _creationCode(
        address _implementation,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            // ERC-1167 minimal proxy
            hex"3d60ad80600a3d3981f3363d3d373d3d3d363d73",
            _implementation,
            hex"5af43d82803e903d91602b57fd5bf3",
            // Append immutable args (chain ID, token contract, token ID)
            abi.encode(chainId, tokenContract, tokenId)
        );
    }
}
