// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title HyperlaneChains
 * @notice Library of Hyperlane domain IDs and mailbox addresses
 * @dev Reference: https://docs.hyperlane.xyz/docs/reference/domains
 */
library HyperlaneChains {
    // ============ Mainnet Domain IDs ============
    uint32 public constant ETHEREUM = 1;
    uint32 public constant OPTIMISM = 10;
    uint32 public constant BSC = 56;
    uint32 public constant GNOSIS = 100;
    uint32 public constant POLYGON = 137;
    uint32 public constant FANTOM = 250;
    uint32 public constant MOONBEAM = 1284;
    uint32 public constant ARBITRUM = 42161;
    uint32 public constant CELO = 42220;
    uint32 public constant AVALANCHE = 43114;
    uint32 public constant BASE = 8453;
    uint32 public constant MONAD = 10143; // Monad Devnet (mainnet TBD)
    
    // ============ Testnet Domain IDs ============
    uint32 public constant SEPOLIA = 11155111;
    uint32 public constant BASE_SEPOLIA = 84532;
    uint32 public constant OPTIMISM_SEPOLIA = 11155420;
    uint32 public constant ARBITRUM_SEPOLIA = 421614;
    
    // ============ Mailbox Addresses (Hyperlane V3) ============
    
    // Mainnet Mailboxes
    address public constant ETHEREUM_MAILBOX = 0xc005dc82818d67AF737725bD4bf75435d065D239;
    address public constant OPTIMISM_MAILBOX = 0xd4C1905BB1D26BC93DAC913e13CaCC278CdCC80D;
    address public constant POLYGON_MAILBOX = 0x5d934f4e2f797775e53561bB72aca21ba36B96BB;
    address public constant ARBITRUM_MAILBOX = 0x979Ca5202784112f4738403dBec5D0F3B9daabB9;
    address public constant BASE_MAILBOX = 0xeA87ae93Fa0019a82A727bfd3eBd1cFCa8f64f1D;
    address public constant AVALANCHE_MAILBOX = 0xFf06aFcaABaDDd1fb08371f9ccA15D73D51FeBD6;
    address public constant BSC_MAILBOX = 0x2971b9Aec44bE4eb673DF1B88cDB57b96eefe8a4;
    address public constant MONAD_MAILBOX = address(0); // TBD when Monad launches Hyperlane
    
    // Testnet Mailboxes
    address public constant SEPOLIA_MAILBOX = 0xfFAEF09B3cd11D9b20d1a19bECca54EEC2884766;
    address public constant BASE_SEPOLIA_MAILBOX = 0x6966b0E55883d49BFB24539356a2f8A673E02039;
    
    /**
     * @notice Get the mailbox address for a given domain
     * @param domain The Hyperlane domain ID
     * @return The mailbox address, or address(0) if not supported
     */
    function getMailbox(uint32 domain) internal pure returns (address) {
        if (domain == ETHEREUM) return ETHEREUM_MAILBOX;
        if (domain == OPTIMISM) return OPTIMISM_MAILBOX;
        if (domain == POLYGON) return POLYGON_MAILBOX;
        if (domain == ARBITRUM) return ARBITRUM_MAILBOX;
        if (domain == BASE) return BASE_MAILBOX;
        if (domain == AVALANCHE) return AVALANCHE_MAILBOX;
        if (domain == BSC) return BSC_MAILBOX;
        if (domain == MONAD) return MONAD_MAILBOX;
        if (domain == SEPOLIA) return SEPOLIA_MAILBOX;
        if (domain == BASE_SEPOLIA) return BASE_SEPOLIA_MAILBOX;
        return address(0);
    }
    
    /**
     * @notice Get chain name for a domain
     */
    function getChainName(uint32 domain) internal pure returns (string memory) {
        if (domain == ETHEREUM) return "Ethereum";
        if (domain == OPTIMISM) return "Optimism";
        if (domain == POLYGON) return "Polygon";
        if (domain == ARBITRUM) return "Arbitrum";
        if (domain == BASE) return "Base";
        if (domain == AVALANCHE) return "Avalanche";
        if (domain == BSC) return "BNB Chain";
        if (domain == MONAD) return "Monad";
        if (domain == SEPOLIA) return "Sepolia";
        if (domain == BASE_SEPOLIA) return "Base Sepolia";
        return "Unknown";
    }
    
    /**
     * @notice Check if a domain is a testnet
     */
    function isTestnet(uint32 domain) internal pure returns (bool) {
        return domain == SEPOLIA || 
               domain == BASE_SEPOLIA || 
               domain == OPTIMISM_SEPOLIA || 
               domain == ARBITRUM_SEPOLIA;
    }
}
