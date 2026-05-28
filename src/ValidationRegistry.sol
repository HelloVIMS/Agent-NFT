// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ValidationRegistry
 * @dev ERC-8004 Validation Registry - On-chain validation status for agents
 * Supports multiple validation methods: TEE, zkML, Staking
 */
contract ValidationRegistry is Ownable, AccessControl {
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    
    enum ValidationMethod {
        None,
        TEE,        // Trusted Execution Environment attestation
        ZKML,       // Zero-knowledge machine learning proof
        Staking,    // Economic stake-based validation
        Manual      // Manual verification by trusted validators
    }
    
    struct Validation {
        bool validated;
        ValidationMethod method;
        address validator;
        uint256 score;      // 0-100 validation confidence
        uint256 validatedAt;
        uint256 expiresAt;
        bytes32 attestationHash;
    }
    
    mapping(uint256 => Validation) public validations;
    mapping(uint256 => Validation[]) public validationHistory;
    
    address public agentRegistry;
    uint256 public defaultValidityPeriod = 30 days;
    
    event ValidationRequested(uint256 indexed agentId, ValidationMethod method);
    event ValidationCompleted(uint256 indexed agentId, address indexed validator, ValidationMethod method, uint256 score);
    event ValidationRevoked(uint256 indexed agentId, address indexed revokedBy);
    event ValidationExpired(uint256 indexed agentId);

    constructor(address _agentRegistry) Ownable(msg.sender) {
        agentRegistry = _agentRegistry;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VALIDATOR_ROLE, msg.sender);
    }

    /**
     * @dev Request validation for an agent (anyone can request, validators fulfill)
     */
    function requestValidation(uint256 agentId, ValidationMethod method) public {
        require(method != ValidationMethod.None, "Invalid validation method");
        emit ValidationRequested(agentId, method);
    }

    /**
     * @dev Complete validation for an agent (validators only)
     * @param agentId The agent token ID
     * @param method Validation method used
     * @param score Confidence score 0-100
     * @param attestationHash Hash of off-chain attestation data
     * @param validityPeriod How long the validation is valid (0 for default)
     */
    function validateAgent(
        uint256 agentId,
        ValidationMethod method,
        uint256 score,
        bytes32 attestationHash,
        uint256 validityPeriod
    ) public onlyRole(VALIDATOR_ROLE) {
        require(score <= 100, "Score must be 0-100");
        require(method != ValidationMethod.None, "Invalid validation method");
        
        uint256 expiry = block.timestamp + (validityPeriod > 0 ? validityPeriod : defaultValidityPeriod);
        
        Validation memory validation = Validation({
            validated: true,
            method: method,
            validator: msg.sender,
            score: score,
            validatedAt: block.timestamp,
            expiresAt: expiry,
            attestationHash: attestationHash
        });
        
        // Store current validation
        validations[agentId] = validation;
        
        // Add to history
        validationHistory[agentId].push(validation);
        
        emit ValidationCompleted(agentId, msg.sender, method, score);
    }

    /**
     * @dev Revoke validation for an agent
     */
    function revokeValidation(uint256 agentId) public onlyRole(VALIDATOR_ROLE) {
        require(validations[agentId].validated, "Agent not validated");
        validations[agentId].validated = false;
        emit ValidationRevoked(agentId, msg.sender);
    }

    /**
     * @dev Get current validation status
     */
    function getValidation(uint256 agentId) public view returns (Validation memory) {
        Validation memory v = validations[agentId];
        
        // Check if expired
        if (v.validated && block.timestamp > v.expiresAt) {
            v.validated = false;
        }
        
        return v;
    }

    /**
     * @dev Check if agent is currently validated
     */
    function isValidated(uint256 agentId) public view returns (bool) {
        Validation memory v = validations[agentId];
        return v.validated && block.timestamp <= v.expiresAt;
    }

    /**
     * @dev Get validation history for an agent
     */
    function getValidationHistory(uint256 agentId) public view returns (Validation[] memory) {
        return validationHistory[agentId];
    }

    /**
     * @dev Add a validator
     */
    function addValidator(address validator) public onlyOwner {
        grantRole(VALIDATOR_ROLE, validator);
    }

    /**
     * @dev Remove a validator
     */
    function removeValidator(address validator) public onlyOwner {
        revokeRole(VALIDATOR_ROLE, validator);
    }

    /**
     * @dev Update default validity period
     */
    function setDefaultValidityPeriod(uint256 period) public onlyOwner {
        defaultValidityPeriod = period;
    }

    /**
     * @dev Update agent registry address
     */
    function setAgentRegistry(address _agentRegistry) public onlyOwner {
        agentRegistry = _agentRegistry;
    }
}
