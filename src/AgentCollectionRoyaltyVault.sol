// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {AgentRoyaltyVault} from "./AgentRoyaltyVault.sol";

/// @notice The parts of AgentCollectionImpl the vault reads (all existing views).
interface IAgentCollectionRoyalty {
    function royaltyReceiver() external view returns (address);
    function agentCreator(uint256 agentId) external view returns (address);
    function getSalesRoyalty(uint256 agentId) external view returns (uint256);
    function protocolFeeRecipient() external view returns (address);
    function protocolSecondaryFeeBps() external view returns (uint256);
}

/**
 * @title AgentCollectionRoyaltyVault
 * @notice Per-token ERC-2981 royalty splitter for factory collections — the
 *         collection counterpart of the identity registry's AgentRoyaltyVault,
 *         with the same release / deferred-payment logic. Deployed at a
 *         deterministic CREATE2 address by AgentCollectionFactory; the
 *         collection's royaltyInfo() names it as receiver.
 *
 *         Splits what marketplaces pay into:
 *           - the creator's sales royalty (`getSalesRoyalty`), to the
 *             collection's royalty splitter when it has one, else to the
 *             token's soulbound creator;
 *           - the protocol's secondary fee (`protocolSecondaryFeeBps`) to the
 *             collection's `protocolFeeRecipient` (the VIMS treasury).
 *         Ratios are read live from the collection at release time.
 */
contract AgentCollectionRoyaltyVault is AgentRoyaltyVault {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentCollectionRoyaltyVault";
    }

    constructor(address collection, uint256 tokenId) AgentRoyaltyVault(collection, tokenId) {}

    function _splitParams() internal view override returns (
        address creator,
        address treasury,
        uint256 creatorBps,
        uint256 systemBps
    ) {
        IAgentCollectionRoyalty c = IAgentCollectionRoyalty(address(registry));
        creator    = c.royaltyReceiver();
        if (creator == address(0)) creator = c.agentCreator(agentId);
        creatorBps = c.getSalesRoyalty(agentId);
        treasury   = c.protocolFeeRecipient();
        systemBps  = treasury == address(0) ? 0 : c.protocolSecondaryFeeBps();
    }
}
