// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AgentRoyaltySplitter} from "./AgentRoyaltySplitter.sol";

/**
 * @title  AgentRoyaltySplitterFactory
 * @notice Permissionless factory that deploys {AgentRoyaltySplitter}
 *         instances with deterministic CREATE2 addresses.
 *
 * @dev    The factory keeps a global list and a per-deployer index so the
 *         frontend can resolve historical splitters without an indexer.
 *         The salt is keccak256(deployer, payees, sharesBps), which means
 *         two deployers can deploy the same payee set without colliding.
 */
import {VimsProvenance} from "./VimsProvenance.sol";

contract AgentRoyaltySplitterFactory is VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentRoyaltySplitterFactory";
    }

    // All splitters ever deployed by this factory.
    address[] private _allSplitters;
    // deployer => splitters they deployed.
    mapping(address => address[]) private _splittersByDeployer;
    // splitter => deployer (0x0 if not deployed by this factory).
    mapping(address => address) public splitterDeployer;

    event SplitterDeployed(
        address indexed splitter,
        address indexed deployer,
        address[]       payees,
        uint256[]       sharesBps,
        bytes32         salt
    );

    error AlreadyDeployed();

    /**
     * @notice Deploy a new {AgentRoyaltySplitter}.
     * @param  payees     Recipient addresses.
     * @param  sharesBps  Per-payee basis points; must sum to 10_000.
     * @return splitter   Address of the deployed splitter.
     */
    function deploySplitter(
        address[] calldata payees,
        uint256[] calldata sharesBps
    ) external returns (address splitter) {
        bytes32 salt = computeSalt(msg.sender, payees, sharesBps);
        address predicted = predictAddress(payees, sharesBps, salt);
        if (predicted.code.length > 0) revert AlreadyDeployed();

        AgentRoyaltySplitter deployed = new AgentRoyaltySplitter{salt: salt}(payees, sharesBps);
        splitter = address(deployed);

        _allSplitters.push(splitter);
        _splittersByDeployer[msg.sender].push(splitter);
        splitterDeployer[splitter] = msg.sender;

        emit SplitterDeployed(splitter, msg.sender, payees, sharesBps, salt);
    }

    /**
     * @notice Predict the CREATE2 address for `(deployer, payees, sharesBps)`.
     * @dev    Useful as a frontend dry-run before broadcasting a tx.
     */
    function predictSplitterAddress(
        address deployer,
        address[] calldata payees,
        uint256[] calldata sharesBps
    ) external view returns (address) {
        bytes32 salt = computeSalt(deployer, payees, sharesBps);
        return predictAddress(payees, sharesBps, salt);
    }

    function predictAddress(
        address[] memory payees,
        uint256[] memory sharesBps,
        bytes32 salt
    ) internal view returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(AgentRoyaltySplitter).creationCode,
            abi.encode(payees, sharesBps)
        );
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode))
        );
        return address(uint160(uint256(hash)));
    }

    function computeSalt(
        address deployer,
        address[] memory payees,
        uint256[] memory sharesBps
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(deployer, payees, sharesBps));
    }

    // ─── Views ──────────────────────────────────────────────────────────────

    function allSplitters() external view returns (address[] memory) {
        return _allSplitters;
    }

    function splittersByDeployer(address deployer) external view returns (address[] memory) {
        return _splittersByDeployer[deployer];
    }

    function totalSplitters() external view returns (uint256) {
        return _allSplitters.length;
    }
}
