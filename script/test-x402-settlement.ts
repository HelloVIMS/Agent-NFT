/**
 * x402 Settlement Test Script
 *
 * Generates off-chain EIP-3009 + EIP-712 signatures and calls
 * AgentX402Receiver.payForService on Base Sepolia.
 *
 * Prerequisites:
 *   - Wallet with Base Sepolia ETH (for gas)
 *   - Wallet with Base Sepolia USDC (for payment)
 *   - Service already registered via RegisterX402Services.s.sol
 *
 * Run:
 *   npx tsx script/test-x402-settlement.ts
 */
import {
  createWalletClient,
  createPublicClient,
  http,
  parseAbi,
  keccak256,
  toHex,
  concat,
  pad,
  encodeAbiParameters,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { baseSepolia } from 'viem/chains'

// === Configuration ===
const PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY as `0x${string}`
const AGENT_X402_RECEIVER = '0xd180DC89270Df505F5d4B7B36e83318f330014A7'
const USDC_BASE_SEPOLIA = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
const RPC_URL = process.env.BASE_SEPOLIA_RPC_URL || 'https://sepolia.base.org'

// === ABIs ===
const X402_ABI = parseAbi([
  'function payForService(uint256 agentId, bytes32 serviceId, address from, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s, uint8 cv, bytes32 cr, bytes32 cs) external returns (uint256 gross)',
  'function hashPaymentCommitment(uint256 agentId, bytes32 serviceId, address token, uint256 amount, bytes32 nonce, uint256 validBefore) public view returns (bytes32)',
  'function getService(uint256 agentId, bytes32 serviceId) external view returns (address, uint256, bool)',
])

const USDC_EIP3009_ABI = parseAbi([
  'function name() view returns (string)',
  'function version() view returns (string)',
  'function DOMAIN_SEPARATOR() view returns (bytes32)',
  'function receiveWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external',
])

// === Types ===
const USDC_TYPES = {
  ReceiveWithAuthorization: [
    { name: 'from', type: 'address' },
    { name: 'to', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'validAfter', type: 'uint256' },
    { name: 'validBefore', type: 'uint256' },
    { name: 'nonce', type: 'bytes32' },
  ],
} as const

const PAYMENT_COMMITMENT_TYPES = {
  PaymentCommitment: [
    { name: 'agentId', type: 'uint256' },
    { name: 'serviceId', type: 'bytes32' },
    { name: 'token', type: 'address' },
    { name: 'amount', type: 'uint256' },
    { name: 'nonce', type: 'bytes32' },
    { name: 'validBefore', type: 'uint256' },
  ],
} as const

async function main() {
  if (!PRIVATE_KEY || !PRIVATE_KEY.startsWith('0x')) {
    console.error('Set DEPLOYER_PRIVATE_KEY env var')
    process.exit(1)
  }

  const account = privateKeyToAccount(PRIVATE_KEY)
  const walletClient = createWalletClient({ account, chain: baseSepolia, transport: http(RPC_URL) })
  const publicClient = createPublicClient({ chain: baseSepolia, transport: http(RPC_URL) })

  // Query USDC domain
  const [usdcName, usdcVersion, usdcDomainSeparator] = await publicClient.multicall({
    contracts: [
      { address: USDC_BASE_SEPOLIA, abi: USDC_EIP3009_ABI, functionName: 'name' },
      { address: USDC_BASE_SEPOLIA, abi: USDC_EIP3009_ABI, functionName: 'version' },
      { address: USDC_BASE_SEPOLIA, abi: USDC_EIP3009_ABI, functionName: 'DOMAIN_SEPARATOR' },
    ],
  })

  const usdcDomain = {
    name: usdcName.result as string,
    version: usdcVersion.result as string,
    chainId: baseSepolia.id,
    verifyingContract: USDC_BASE_SEPOLIA as `0x${string}`,
  }

  const x402Domain = {
    name: 'AgentX402Receiver',
    version: '1',
    chainId: baseSepolia.id,
    verifyingContract: AGENT_X402_RECEIVER as `0x${string}`,
  }

  // Test parameters (update after minting agents)
  const agentId = BigInt(process.env.TEST_AGENT_ID || '1')
  const serviceId = keccak256(toHex('test-service/' + agentId.toString()))
  const now = Math.floor(Date.now() / 1000)
  const validAfter = 0n
  const validBefore = BigInt(now + 300)
  const nonce = pad(toHex(BigInt(Math.floor(Math.random() * 1e18))))

  // Get service price
  const service = await publicClient.readContract({
    address: AGENT_X402_RECEIVER as `0x${string}`,
    abi: X402_ABI,
    functionName: 'getService',
    args: [agentId, serviceId],
  })
  const price = service[1]
  console.log('Service price:', price.toString(), 'USDC (6 dec)')

  // === 1. Sign EIP-3009 (USDC receiveWithAuthorization) ===
  const usdcMessage = {
    from: account.address,
    to: AGENT_X402_RECEIVER as `0x${string}`,
    value: price,
    validAfter,
    validBefore,
    nonce,
  }

  const usdcSig = await account.signTypedData({
    domain: usdcDomain,
    types: USDC_TYPES,
    primaryType: 'ReceiveWithAuthorization',
    message: usdcMessage,
  })
  const usdcSigParts = parseSignature(usdcSig)
  console.log('EIP-3009 signature:', usdcSig)

  // === 2. Sign EIP-712 PaymentCommitment ===
  const commitmentMessage = {
    agentId,
    serviceId,
    token: USDC_BASE_SEPOLIA as `0x${string}`,
    amount: price,
    nonce,
    validBefore,
  }

  const commitSig = await account.signTypedData({
    domain: x402Domain,
    types: PAYMENT_COMMITMENT_TYPES,
    primaryType: 'PaymentCommitment',
    message: commitmentMessage,
  })
  const commitSigParts = parseSignature(commitSig)
  console.log('EIP-712 commitment signature:', commitSig)

  // === 3. Call payForService ===
  console.log('Broadcasting payForService...')
  const txHash = await walletClient.writeContract({
    address: AGENT_X402_RECEIVER as `0x${string}`,
    abi: X402_ABI,
    functionName: 'payForService',
    args: [
      agentId,
      serviceId,
      account.address,
      validAfter,
      validBefore,
      nonce,
      usdcSigParts.v,
      usdcSigParts.r,
      usdcSigParts.s,
      commitSigParts.v,
      commitSigParts.r,
      commitSigParts.s,
    ],
  })

  console.log('Transaction broadcast:', txHash)
  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash })
  console.log('Confirmed in block:', receipt.blockNumber)
}

function parseSignature(sig: `0x${string}`) {
  const hex = sig.slice(2)
  const r = `0x${hex.slice(0, 64)}` as `0x${string}`
  const s = `0x${hex.slice(64, 128)}` as `0x${string}`
  const v = parseInt(hex.slice(128, 130), 16)
  return { r, s, v }
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
