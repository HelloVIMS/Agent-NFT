// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {ITipBeneficiary} from "../hooks/TipJarHook.sol";

/// @notice Read-only surface from `AgentIdentityRegistry` consumed by this resolver.
interface IIdentityRegistryView {
    function agents(uint256 agentId) external view returns (
        string memory name,
        address tbaAddress,
        uint256 createdAt,
        bool active,
        address reputationAnchor
    );
    function ownerOf(uint256 agentId) external view returns (address);
}

/**
 * @title IdentityTipBeneficiaryResolver
 * @notice Concrete `ITipBeneficiary` for {TipJarHook} that resolves the
 *         beneficiary as the agent's TBA when set, else the agent's owner.
 *
 * @dev    Strict policy: an inactive or non-existent agent returns
 *         `address(0)`, which makes {TipJarHook.tip} revert with
 *         `ZeroBeneficiary`. This protects tippers from sending ETH to
 *         deactivated agents.
 */
contract IdentityTipBeneficiaryResolver is ITipBeneficiary {
    error ZeroRegistry();

    IIdentityRegistryView public immutable identity;

    constructor(address _identity) {
        if (_identity == address(0)) revert ZeroRegistry();
        identity = IIdentityRegistryView(_identity);
    }

    /// @inheritdoc ITipBeneficiary
    function tipBeneficiary(uint256 agentId) external view returns (address) {
        // `ownerOf` reverts if the token doesn't exist — defer to it for
        // existence-checking so we never tip into a burnt or unminted id.
        address holder = identity.ownerOf(agentId);
        (, address tba, , bool active,) = identity.agents(agentId);
        if (!active) return address(0);
        return tba == address(0) ? holder : tba;
    }
}
