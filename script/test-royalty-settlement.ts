/**
 * x402 Royalty Settlement Test
 *
 * Buyer B (separate wallet) pays for service on agent 22 (5% royalty, TBA set).
 * Verifies on-chain that:
 *   - 0.5% goes to treasury
 *   - 5%   goes to creator (mint wallet)
 *   - 94.5% goes to TBA
 *
 * Run:
 *   BUYER_PRIVATE_KEY=<pk> BASE_SEPOLIA_RPC_URL=<rpc> \
 *     npx tsx script/test-royalty-settlement.ts
 */
import {
  createWalletClient, createPublicClient, http, parseAbi, keccak256, toHex, pad,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { baseSepolia } from 'viem/chains'

const BUYER_PK = process.env.BUYER_PRIVATE_KEY as `0x${string}`
const AGENT_X402_RECEIVER = '0xd180DC89270Df505F5d4B7B36e83318f330014A7'
const USDC = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
const IDENTITY_REGISTRY = '0xfE1ef66Ba95891d3cDf6FB83FE1444Bc3bB9FEeF'
const TBA = '0x9B215Cd5cbf5A742A1ACa750AF6463622F0F4996' as const
const CREATOR = '0xE48840eD6678218Bd21dF2671b98bCF23de661b9' as const
const TREASURY = '0x1804c8ab1f12e6bbf3894d4083f33e07309d1f38' as const
const AGENT_ID = 22n
const SERVICE_ID = '0xd49e85d2d0dbe42982d9764d9a836c01bcfa1e30ce9a22f3de50774891bfaca6' as const
const RPC_URL = process.env.BASE_SEPOLIA_RPC_URL || 'https://sepolia.base.org'

const X402_ABI = parseAbi([
  'function payForService(uint256 agentId, bytes32 serviceId, address from, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s, uint8 cv, bytes32 cr, bytes32 cs) external returns (uint256 gross)',
])
const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function name() view returns (string)',
  'function version() view returns (string)',
])

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

function parseSignature(sig: `0x${string}`) {
  const hex = sig.slice(2)
  return {
    r: `0x${hex.slice(0, 64)}` as `0x${string}`,
    s: `0x${hex.slice(64, 128)}` as `0x${string}`,
    v: parseInt(hex.slice(128, 130), 16),
  }
}

async function main() {
  if (!BUYER_PK) throw new Error('Set BUYER_PRIVATE_KEY')
  const account = privateKeyToAccount(BUYER_PK)
  const wallet = createWalletClient({ account, chain: baseSepolia, transport: http(RPC_URL) })
  const pub = createPublicClient({ chain: baseSepolia, transport: http(RPC_URL) })

  // Snapshot balances
  const [b0Buyer, b0Treasury, b0Creator, b0TBA] = await Promise.all([
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [account.address] }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [TREASURY] }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [CREATOR] }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [TBA] }),
  ])
  console.log('Initial USDC balances:')
  console.log('  buyer:   ', b0Buyer.toString())
  console.log('  treasury:', b0Treasury.toString())
  console.log('  creator: ', b0Creator.toString())
  console.log('  tba:     ', b0TBA.toString())

  const [usdcName, usdcVersion] = await Promise.all([
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'name' }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'version' }),
  ])

  const usdcDomain = { name: usdcName, version: usdcVersion, chainId: baseSepolia.id, verifyingContract: USDC as `0x${string}` }
  const x402Domain = { name: 'AgentX402Receiver', version: '1', chainId: baseSepolia.id, verifyingContract: AGENT_X402_RECEIVER as `0x${string}` }

  const now = Math.floor(Date.now() / 1000)
  const validAfter = 0n
  const validBefore = BigInt(now + 600)
  const nonce = pad(toHex(BigInt(Math.floor(Math.random() * 1e18))))
  const price = 100000n

  const usdcSig = await account.signTypedData({
    domain: usdcDomain,
    types: USDC_TYPES,
    primaryType: 'ReceiveWithAuthorization',
    message: { from: account.address, to: AGENT_X402_RECEIVER as `0x${string}`, value: price, validAfter, validBefore, nonce },
  })
  const u = parseSignature(usdcSig)
  const commitSig = await account.signTypedData({
    domain: x402Domain,
    types: PAYMENT_COMMITMENT_TYPES,
    primaryType: 'PaymentCommitment',
    message: { agentId: AGENT_ID, serviceId: SERVICE_ID, token: USDC as `0x${string}`, amount: price, nonce, validBefore },
  })
  const c = parseSignature(commitSig)

  console.log('Broadcasting payForService from buyer B...')
  const txHash = await wallet.writeContract({
    address: AGENT_X402_RECEIVER as `0x${string}`,
    abi: X402_ABI,
    functionName: 'payForService',
    args: [AGENT_ID, SERVICE_ID, account.address, validAfter, validBefore, nonce, u.v, u.r, u.s, c.v, c.r, c.s],
  })
  console.log('tx:', txHash)
  const rcpt = await pub.waitForTransactionReceipt({ hash: txHash })
  console.log('confirmed in block:', rcpt.blockNumber)

  const [b1Buyer, b1Treasury, b1Creator, b1TBA] = await Promise.all([
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [account.address] }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [TREASURY] }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [CREATOR] }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [TBA] }),
  ])
  console.log('\nFinal USDC balances:')
  console.log('  buyer:   ', b1Buyer.toString(), '(delta', (b1Buyer - b0Buyer).toString() + ')')
  console.log('  treasury:', b1Treasury.toString(), '(delta', (b1Treasury - b0Treasury).toString() + ')')
  console.log('  creator: ', b1Creator.toString(), '(delta', (b1Creator - b0Creator).toString() + ')')
  console.log('  tba:     ', b1TBA.toString(), '(delta', (b1TBA - b0TBA).toString() + ')')

  console.log('\nExpected splits for 100000 USDC payment:')
  console.log('  buyer  -100000')
  console.log('  treasury +500    (0.5% systemFeeBps=50)')
  console.log('  creator  +5000   (5% creatorRoyaltyBps=500)')
  console.log('  tba      +94500  (remainder to TBA)')

  const ok =
    (b1Buyer - b0Buyer) === -100000n &&
    (b1Treasury - b0Treasury) === 500n &&
    (b1Creator - b0Creator) === 5000n &&
    (b1TBA - b0TBA) === 94500n
  console.log(ok ? '\n✓ ALL SPLITS VERIFIED' : '\n✗ SPLIT MISMATCH')
  process.exit(ok ? 0 : 1)
}

main().catch((e) => { console.error(e); process.exit(1) })
