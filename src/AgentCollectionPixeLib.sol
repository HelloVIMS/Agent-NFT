// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

/**
 * @title  AgentCollectionPixeLib
 * @notice External library that owns the Pixelog (.pixe) version-management
 *         surface for {AgentCollectionImpl}.
 *
 * @dev    Called via DELEGATECALL from {AgentCollectionImpl}. Storage,
 *         `address(this)`, and `msg.sender` are the impl's. Extracted to
 *         keep the impl bytecode under the EIP-170 24,576-byte ceiling
 *         after `collectionBaseURI` was added (audit P0 invariant B.2).
 *
 *         Storage refs are passed in explicitly so the library never
 *         declares state of its own — the impl owns the canonical layout.
 *
 *         Logic is byte-for-byte equivalent to the original inlined
 *         block. Events are mirrored here so they emit from the impl
 *         contract in the DELEGATECALL frame.
 */
library AgentCollectionPixeLib {
    // ============ Types (canonical layout — keep in sync with impl) ===========
    struct PixeVersion {
        string  arweaveTxId;
        bytes32 contentHash;
        uint8   versionType;       // 0=delta, 1=consolidated
        uint48  timestamp;
        uint16  baseVersion;
        string  description;
    }

    struct ConsolidationRecord {
        uint16  fromVersion;
        uint16  toVersion;
        bytes32 merkleRoot;
        uint16  resultVersion;
        uint48  consolidatedAt;
    }

    // ============ Errors (mirror impl's set) ============
    error EmptyInput();
    error MaxReached();
    error NotExists();
    error InvalidValue();

    // ============ Events (mirror impl's set) ============
    event PixeVersionAdded(
        uint256 indexed agentId,
        uint256 indexed version,
        bytes32 contentHash,
        uint8 versionType,
        string arweaveTxId
    );
    event PixeConsolidated(
        uint256 indexed agentId,
        uint16 fromVersion,
        uint16 toVersion,
        uint16 indexed resultVersion,
        bytes32 merkleRoot
    );

    // ============ State-mutating ============

    /// @notice Append a delta (or initial consolidated) version for `agentId`.
    /// @dev    Caller must validate `ownerOf(agentId) == msg.sender` BEFORE
    ///         calling; the library cannot reach the ERC-721 storage of the
    ///         impl from a separate file without re-implementing it.
    function addPixeVersion(
        mapping(uint256 => PixeVersion[]) storage versions,
        mapping(uint256 => uint16)        storage latestConsolidated,
        uint256 maxVersions,
        uint256 agentId,
        string calldata arweaveTxId,
        bytes32 contentHash,
        string calldata description
    ) external returns (uint256 version) {
        if (bytes(arweaveTxId).length == 0)        revert EmptyInput();
        if (contentHash == bytes32(0))             revert EmptyInput();
        if (versions[agentId].length >= maxVersions) revert MaxReached();

        version = versions[agentId].length;
        uint16 baseVer = version > 0 ? uint16(version - 1) : 0;

        versions[agentId].push(PixeVersion({
            arweaveTxId: arweaveTxId,
            contentHash: contentHash,
            versionType: version == 0 ? 1 : 0,
            timestamp:   uint48(block.timestamp),
            baseVersion: baseVer,
            description: description
        }));

        if (version == 0) {
            latestConsolidated[agentId] = 0;
        }

        emit PixeVersionAdded(agentId, version, contentHash, version == 0 ? 1 : 0, arweaveTxId);
    }

    /// @notice Append a fresh consolidated version that supersedes the
    ///         delta range `[fromVersion, toVersion]`.
    function consolidateVersions(
        mapping(uint256 => PixeVersion[])         storage versions,
        mapping(uint256 => ConsolidationRecord[]) storage consolidations,
        mapping(uint256 => uint16)                storage latestConsolidated,
        uint256 maxVersions,
        uint256 agentId,
        string calldata arweaveTxId,
        bytes32 contentHash,
        bytes32 merkleRoot,
        string calldata description
    ) external returns (uint256 version) {
        if (bytes(arweaveTxId).length == 0)        revert EmptyInput();
        if (contentHash == bytes32(0))             revert EmptyInput();
        if (merkleRoot == bytes32(0))              revert EmptyInput();
        if (versions[agentId].length >= maxVersions) revert MaxReached();
        if (versions[agentId].length == 0)         revert NotExists();

        uint16 fromVer = latestConsolidated[agentId];
        uint16 toVer   = uint16(versions[agentId].length - 1);
        if (toVer <= fromVer) revert InvalidValue();

        version = versions[agentId].length;

        versions[agentId].push(PixeVersion({
            arweaveTxId: arweaveTxId,
            contentHash: contentHash,
            versionType: 1,
            timestamp:   uint48(block.timestamp),
            baseVersion: toVer,
            description: description
        }));

        consolidations[agentId].push(ConsolidationRecord({
            fromVersion:    fromVer,
            toVersion:      toVer,
            merkleRoot:     merkleRoot,
            resultVersion:  uint16(version),
            consolidatedAt: uint48(block.timestamp)
        }));

        latestConsolidated[agentId] = uint16(version);

        emit PixeConsolidated(agentId, fromVer, toVer, uint16(version), merkleRoot);
        emit PixeVersionAdded(agentId, version, contentHash, 1, arweaveTxId);
    }
}
