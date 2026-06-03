// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

/**
 * @title IMailbox
 * @notice Hyperlane Mailbox interface for cross-chain messaging
 */
interface IMailbox {
    /**
     * @notice Dispatches a message to the destination domain & recipient
     * @param destinationDomain Domain of destination chain
     * @param recipientAddress Address of recipient on destination chain
     * @param messageBody Raw bytes content of message
     * @return messageId The message ID
     */
    function dispatch(
        uint32 destinationDomain,
        bytes32 recipientAddress,
        bytes calldata messageBody
    ) external payable returns (bytes32 messageId);

    /**
     * @notice Returns the required payment for a dispatch
     * @param destinationDomain Domain of destination chain
     * @param messageBody Raw bytes content of message
     * @return fee The required fee
     */
    function quoteDispatch(
        uint32 destinationDomain,
        bytes32 recipientAddress,
        bytes calldata messageBody
    ) external view returns (uint256 fee);

    /**
     * @notice Returns the local domain
     */
    function localDomain() external view returns (uint32);
}

/**
 * @title IMessageRecipient
 * @notice Interface for contracts that receive Hyperlane messages
 */
interface IMessageRecipient {
    /**
     * @notice Handle an interchain message
     * @param origin Domain of origin chain
     * @param sender Address of sender on origin chain
     * @param message Raw bytes content of message
     */
    function handle(
        uint32 origin,
        bytes32 sender,
        bytes calldata message
    ) external payable;
}

/**
 * @title IInterchainSecurityModule
 * @notice Interface for security modules
 */
interface IInterchainSecurityModule {
    /**
     * @notice Returns whether the message was verified by the ISM
     */
    function verify(
        bytes calldata metadata,
        bytes calldata message
    ) external returns (bool);
}
