// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC6551RegistryMinLib {
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address);
}

interface IX402ServiceRegistrarMinLib {
    function registerServiceForNFT(
        address nftContract,
        uint256 tokenId,
        bytes32 serviceId,
        address token,
        uint256 price
    ) external;
}

/**
 * @title  AgentCollectionAtomicLib
 * @notice External library used via DELEGATECALL from {AgentCollectionImpl}
 *         to keep the ERC-6551 + x402 dispatcher selectors out of the impl
 *         bytecode (EIP-170 ceiling). Logic is identical to inlining; the
 *         only reason it lives here is bytecode budget.
 *
 * @dev    Because this is a Solidity *external* library, calls are
 *         delegatecalled by the linker. `address(this)` and `msg.sender`
 *         observed inside these functions are the impl's, which is critical
 *         for the receiver's `trustedRegistrarFor[collection]` check.
 */
library AgentCollectionAtomicLib {
    /// @dev Canonical ERC-6551 registry (same address on every chain).
    address internal constant ERC6551_REGISTRY   = 0x000000006551c19487814612e58FE06813775758;
    /// @dev VIMS AgentTBA implementation (Base Sepolia).
    address internal constant TBA_IMPLEMENTATION = 0x50183A126Ad080e88eDE5166bEaDAa0DdaAaa24C;
    /// @dev {AgentX402Receiver} proxy (Base Sepolia).
    address internal constant X402_RECEIVER      = 0xd180DC89270Df505F5d4B7B36e83318f330014A7;

    /// @notice Deploy (or resolve) the ERC-6551 token-bound account for
    ///         `agentId` and, if `servicePrice > 0`, register a priced x402
    ///         service for it on the receiver. Storage writes back to the
    ///         collection (`agents[id].tbaAddress`) are handled by the caller
    ///         so this function stays storage-layout-free.
    /// @return tba The deployed (or pre-existing) token-bound account.
    function deployTBAAndRegisterService(
        uint256 agentId,
        bytes32 tbaSalt,
        bytes32 serviceId,
        address paymentToken,
        uint256 servicePrice
    ) external returns (address tba) {
        tba = IERC6551RegistryMinLib(ERC6551_REGISTRY).createAccount(
            TBA_IMPLEMENTATION,
            tbaSalt,
            block.chainid,
            address(this),
            agentId
        );

        if (servicePrice > 0) {
            IX402ServiceRegistrarMinLib(X402_RECEIVER).registerServiceForNFT(
                address(this),
                agentId,
                serviceId,
                paymentToken,
                servicePrice
            );
        }
    }
}
