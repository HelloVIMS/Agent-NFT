import { createWalletClient, createPublicClient, http, parseAbi, pad, toHex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { baseSepolia } from 'viem/chains'

async function main() {
const BUYER_PK = process.env.BUYER_PRIVATE_KEY as `0x${string}`
const X402 = '0xd180DC89270Df505F5d4B7B36e83318f330014A7' as const
const USDC = '0x036CbD53842c5426634e7929541eC2318f3dCF7e' as const
const CREATOR = '0xE48840eD6678218Bd21dF2671b98bCF23de661b9' as const
const TREASURY = '0x1804c8ab1f12e6bbf3894d4083f33e07309d1f38' as const
const TBA = '0x5807d825a96fe28554cb4969564ea6c44b8f2a37' as const
const AGENT_ID = 24n
const SERVICE_ID = '0x95a3e94a3ece76d0fe366e51940ebbe604e36f606565e8057eb8349d6bde4c08' as const
const X402_ABI = parseAbi(['function payForService(uint256,bytes32,address,uint256,uint256,bytes32,uint8,bytes32,bytes32,uint8,bytes32,bytes32) returns (uint256)'])
const E_ABI = parseAbi(['function balanceOf(address) view returns (uint256)','function name() view returns (string)','function version() view returns (string)'])
const UT = { ReceiveWithAuthorization: [{name:'from',type:'address'},{name:'to',type:'address'},{name:'value',type:'uint256'},{name:'validAfter',type:'uint256'},{name:'validBefore',type:'uint256'},{name:'nonce',type:'bytes32'}]} as const
const PT = { PaymentCommitment: [{name:'agentId',type:'uint256'},{name:'serviceId',type:'bytes32'},{name:'token',type:'address'},{name:'amount',type:'uint256'},{name:'nonce',type:'bytes32'},{name:'validBefore',type:'uint256'}]} as const
const ps = (sig: `0x${string}`) => { const h = sig.slice(2); return {r:`0x${h.slice(0,64)}` as `0x${string}`,s:`0x${h.slice(64,128)}` as `0x${string}`,v:parseInt(h.slice(128,130),16)} }
const account = privateKeyToAccount(BUYER_PK)
const wallet = createWalletClient({account,chain:baseSepolia,transport:http()})
const pub = createPublicClient({chain:baseSepolia,transport:http()})

const [b0B,b0T,b0C,b0TBA] = await Promise.all([
  pub.readContract({address:USDC,abi:E_ABI,functionName:'balanceOf',args:[account.address]}),
  pub.readContract({address:USDC,abi:E_ABI,functionName:'balanceOf',args:[TREASURY]}),
  pub.readContract({address:USDC,abi:E_ABI,functionName:'balanceOf',args:[CREATOR]}),
  pub.readContract({address:USDC,abi:E_ABI,functionName:'balanceOf',args:[TBA]}),
])
console.log('before:', { buyer:b0B.toString(), treasury:b0T.toString(), creator:b0C.toString(), tba:b0TBA.toString() })

const [n,v] = await Promise.all([pub.readContract({address:USDC,abi:E_ABI,functionName:'name'}),pub.readContract({address:USDC,abi:E_ABI,functionName:'version'})])
const uD = {name:n,version:v,chainId:baseSepolia.id,verifyingContract:USDC}
const xD = {name:'AgentX402Receiver',version:'1',chainId:baseSepolia.id,verifyingContract:X402}
const validBefore = BigInt(Math.floor(Date.now()/1000)+600)
const nonce = pad(toHex(BigInt(Math.floor(Math.random()*1e18))))
const price = 100000n
const us = await account.signTypedData({domain:uD,types:UT,primaryType:'ReceiveWithAuthorization',message:{from:account.address,to:X402,value:price,validAfter:0n,validBefore,nonce}})
const cs = await account.signTypedData({domain:xD,types:PT,primaryType:'PaymentCommitment',message:{agentId:AGENT_ID,serviceId:SERVICE_ID,token:USDC,amount:price,nonce,validBefore}})
const u = ps(us), c = ps(cs)
const tx = await wallet.writeContract({address:X402,abi:X402_ABI,functionName:'payForService',args:[AGENT_ID,SERVICE_ID,account.address,0n,validBefore,nonce,u.v,u.r,u.s,c.v,c.r,c.s]})
console.log('tx:',tx)
await pub.waitForTransactionReceipt({hash:tx})
await new Promise(r=>setTimeout(r,3000))
const [b1B,b1T,b1C,b1TBA] = await Promise.all([
  pub.readContract({address:USDC,abi:E_ABI,functionName:'balanceOf',args:[account.address]}),
  pub.readContract({address:USDC,abi:E_ABI,functionName:'balanceOf',args:[TREASURY]}),
  pub.readContract({address:USDC,abi:E_ABI,functionName:'balanceOf',args:[CREATOR]}),
  pub.readContract({address:USDC,abi:E_ABI,functionName:'balanceOf',args:[TBA]}),
])
console.log('deltas:', { buyer:(b1B-b0B).toString(), treasury:(b1T-b0T).toString(), creator:(b1C-b0C).toString(), tba:(b1TBA-b0TBA).toString() })
const ok = (b1B-b0B)===-100000n && (b1T-b0T)===500n && (b1C-b0C)===5000n && (b1TBA-b0TBA)===94500n
console.log(ok ? 'OK: splits verified' : 'FAIL: split mismatch')
}
main().catch(e=>{console.error(e);process.exit(1)})
