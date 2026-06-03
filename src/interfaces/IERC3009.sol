// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

/**
 * @title IERC3009
 * @notice Minimal EIP-3009 interface — the authorization standard used by
 *         USDC (and most regulated stablecoins) and by the Coinbase x402
 *         payment protocol.
 * @dev `receiveWithAuthorization` requires `to == msg.sender`, which prevents
 *      a signed authorization from being redirected by a third party. This is
 *      the variant x402 facilitators use for settlement.
 */
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}
