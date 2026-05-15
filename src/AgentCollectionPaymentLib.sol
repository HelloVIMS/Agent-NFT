// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  AgentCollectionPaymentLib
 * @notice External library that handles primary-mint payment routing.
 *
 * @dev    Called via DELEGATECALL from {AgentCollectionImpl}, so `msg.value`,
 *         `address(this)`, and storage are the impl's. Extracted out of the
 *         impl purely to keep the impl bytecode under the EIP-170 24,576-byte
 *         ceiling once the generative-drop `collectionBaseURI` feature was
 *         added. Logic is otherwise identical to the original inlined block.
 */
library AgentCollectionPaymentLib {
    error TransferFailed();

    event ProtocolFeeCollected(address indexed recipient, uint256 amount);

    /**
     * @notice Split `msg.value` between the protocol fee recipient and the
     *         creator (or royalty splitter).
     * @param  protocolRecipient Protocol fee destination. If zero, the fee is
     *                           skipped and the full payment goes to the
     *                           creator recipient.
     * @param  protocolBps       Protocol cut in basis points (out of 10000).
     * @param  creatorRecipient  Destination for the post-fee remainder.
     */
    function splitMintPayment(
        address protocolRecipient,
        uint256 protocolBps,
        address creatorRecipient
    ) external {
        if (msg.value == 0) return;

        uint256 protocolFee = (msg.value * protocolBps) / 10000;
        uint256 creatorRevenue = msg.value - protocolFee;

        if (protocolFee > 0 && protocolRecipient != address(0)) {
            (bool ok, ) = protocolRecipient.call{value: protocolFee}("");
            if (!ok) revert TransferFailed();
            emit ProtocolFeeCollected(protocolRecipient, protocolFee);
        }

        if (creatorRevenue > 0) {
            (bool ok, ) = creatorRecipient.call{value: creatorRevenue}("");
            if (!ok) revert TransferFailed();
        }
    }
}
