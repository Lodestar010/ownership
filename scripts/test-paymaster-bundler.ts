import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import {
  sponsorshipDigest,
  buildPaymasterAndData,
  signSponsorship,
  packAccountGasLimits,
  packGasFees,
} from "./sponsor-digest";

/**
 * Live-bundler proof for the ArcPaymaster (ERC-4337 v0.7, Arc testnet).
 *
 * Proves end-to-end that our paymaster sponsors a REAL user operation through
 * the live Pimlico bundler:
 *   1. deploys a SimpleAccountFactory (one cheap tx, DEPLOYER_KEY)
 *   2. builds a counterfactual SimpleAccount (fresh random owner, no funds)
 *   3. funds it with 0.02 USDC for the registrar's 0.01 matching fee
 *      (the paymaster sponsors GAS; the 0.01 value comes from the account)
 *   4. builds a v0.7 PackedUserOperation: initCode deploys the account,
 *      callData = account.execute(registrar.register(<unique 7+ char name>))
 *   5. signs the canonical sponsorship digest with DEPLOYER_KEY
 *      (== the paymaster's verifyingSigner) using scripts/sponsor-digest.ts
 *      (proven byte-equal to the contract in test/paymaster-digest.test.ts)
 *   6. estimates gas via Pimlico, re-signs with final values, submits via
 *      eth_sendUserOperation, polls for the receipt
 *   7. verifies on-chain: registry owner == account AND paymaster deposit decreased
 *
 * Run:  DEPLOYER_KEY=0x... npx hardhat run scripts/test-paymaster-bundler.ts --network arcTestnet
 * The key is used ONLY to deploy the factory, fund the test account, and sign
 * the paymaster digest. It is never logged or written anywhere.
 */

// ---- Live addresses (verified on-chain 2026-10-02) ----
const PAYMASTER = "0xcd629172f31d9a25279Ac5fAB333312dC63De67c";
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const REGISTRAR = "0xb8351Bcc980dA96b091C42092b8d53A7C647E35b";
const REGISTRY = "0x523553fC7fC78F97386F0740847d9E594119D8Bb";
const PIMLICO_URL = "https://public.pimlico.io/v2/5042002/rpc";
const EXPECTED_CHAIN_ID = 5042002n;
const OP_REGISTER = 1;
const ROOT_NODE = "0x" + "00".repeat(32);

const ENTRYPOINT_ABI = [
  "function getNonce(address sender, uint192 key) view returns (uint256)",
  "function getUserOpHash((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature) userOp) view returns (bytes32)",
];
const REGISTRY_ABI = ["function owner(bytes32 node) view returns (address)"];
const PAYMASTER_ABI = [
  "function verifyingSigner() view returns (address)",
  "function depositBalance() view returns (uint256)",
  "function allowedOpType(address target, bytes4 selector) view returns (uint8)",
];
const REGISTRAR_ABI = [
  "function register(string label, address newOwner) payable",
  "function matchingFee() view returns (uint256)",
];

function nodeForLabel(label: string): string {
  return ethers.keccak256(ethers.concat([ROOT_NODE, ethers.keccak256(ethers.toUtf8Bytes(label))]));
}

function short(addr: string): string {
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}

/** Raw JSON-RPC call so bundler errors print in full (diagnostic gold). */
async function pimlico(method: string, params: unknown[]): Promise<any> {
  const res = await fetch(PIMLICO_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const json: any = await res.json();
  if (json.error) {
    console.log(`--- Pimlico ${method} error ---`);
    console.log(JSON.stringify(json.error, null, 2));
    throw new Error(`Pimlico ${method}: ${json.error.message ?? "unknown error"}`);
  }
  return json.result;
}

function fail(reason: string): never {
  console.log(`PAYMASTER PROOF: FAIL — ${reason}`);
  process.exit(1);
}

async function main() {
  console.log("== ArcPaymaster live-bundler proof ==");
  const key = process.env.DEPLOYER_KEY;
  if (!key) fail("DEPLOYER_KEY not set in env");

  const provider = ethers.provider;
  const network = await provider.getNetwork();
  if (network.chainId !== EXPECTED_CHAIN_ID) fail(`wrong chain: ${network.chainId}`);

  const deployer = new ethers.Wallet(key, provider);
  const deployerAddr = await deployer.getAddress();
  console.log(`deployer: ${short(deployerAddr)}`);

  const paymaster = new ethers.Contract(PAYMASTER, PAYMASTER_ABI, provider);
  const registry = new ethers.Contract(REGISTRY, REGISTRY_ABI, provider);
  const entrypoint = new ethers.Contract(ENTRYPOINT, ENTRYPOINT_ABI, provider);
  const registrar = new ethers.Contract(REGISTRAR, REGISTRAR_ABI, provider);
  const registrarIface = new ethers.Interface(REGISTRAR_ABI);

  // 1. we must hold the verifying signer key, or sponsorship is impossible
  const signerOnChain: string = await paymaster.verifyingSigner();
  if (signerOnChain.toLowerCase() !== deployerAddr.toLowerCase())
    fail(`verifyingSigner ${short(signerOnChain)} != deployer — cannot sign`);
  console.log("verifying signer: OK");

  // 2. allowlist sanity: registrar.register must be OP_REGISTER
  const registerSel: string = registrarIface.getFunction("register")!.selector;
  const allowed: bigint = await paymaster.allowedOpType(REGISTRAR, registerSel);
  if (allowed !== BigInt(OP_REGISTER)) fail(`register not allowlisted (got ${allowed})`);
  console.log("allowlist: register -> OP_REGISTER OK");

  const depositBefore: bigint = await paymaster.depositBalance();
  console.log(`deposit before: ${ethers.formatEther(depositBefore)} USDC`);
  if (depositBefore === 0n) fail("paymaster deposit is empty");

  // 3. SimpleAccountFactory (fresh deploy; ~10.7KB, cheap on Arc)
  const aa = JSON.parse(fs.readFileSync(path.join(__dirname, "aa-artifacts.json"), "utf8"));
  const factory = await (
    await new ethers.ContractFactory(aa.factoryAbi, aa.factoryBytecode, deployer).deploy(ENTRYPOINT)
  ).waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log(`factory: ${short(factoryAddr)}`);

  // 4. fresh random owner, counterfactual sender
  const owner = ethers.Wallet.createRandom();
  const ownerSigner = owner.connect(provider);
  const salt = ethers.hexlify(ethers.randomBytes(32));
  const sender: string = await factory.getFunction("getAddress")(owner.address, salt);
  console.log(`account: ${short(sender)} (counterfactual)`);

  // 5. unique 7+ char name, must be unregistered
  const rand = [...ethers.randomBytes(4)].map((b) => "0123456789abcdef"[b % 16]).join("");
  const label = `pimlico-proof-${rand}`;
  const node = nodeForLabel(label);
  if ((await registry.owner(node)) !== ethers.ZeroAddress) fail(`name collision: ${label}`);
  console.log(`name: ${label}.arc`);

  // 6. fund the account for the matching fee (read live; paymaster covers gas only).
  //    The fresh account is not family-free, so register() requires the fee.
  const matchingFee: bigint = await registrar.matchingFee();
  console.log(`matching fee (live): ${ethers.formatEther(matchingFee)} USDC`);
  if (matchingFee === 0n) fail("matching fee is 0 — expected a positive placeholder");
  const fundAmount = matchingFee * 2n;
  console.log(`funding account ${ethers.formatEther(fundAmount)} USDC...`);
  await (await deployer.sendTransaction({ to: sender, value: fundAmount })).wait();

  // 7. initCode + callData
  const initCode =
    factoryAddr + factory.interface.encodeFunctionData("createAccount", [owner.address, salt]).slice(2);
  const inner = registrarIface.encodeFunctionData("register", [label, sender]);
  const accountIface = new ethers.Interface(aa.accountAbi);
  if (accountIface.getFunction("execute")!.selector !== "0xb61d27f6")
    fail("SimpleAccount.execute selector mismatch");
  const callData = accountIface.encodeFunctionData("execute", [REGISTRAR, matchingFee, inner]);

  const nonce: bigint = await entrypoint.getNonce(sender, 0);
  const block = await provider.getBlock("latest");
  const now = block!.timestamp;
  const validUntil = now + 3600;
  const validAfter = now - 300;

  // 8. gas price (Pimlico's suggestion, with RPC fallback)
  let maxFee: bigint;
  let maxPrio: bigint;
  try {
    const gp: any = await pimlico("pimlico_getUserOperationGasPrice", []);
    maxFee = BigInt(gp.standard.maxFeePerGas);
    maxPrio = BigInt(gp.standard.maxPriorityFeePerGas);
  } catch {
    const gp = (await provider.getFeeData()).gasPrice ?? 0n;
    maxPrio = gp;
    maxFee = gp * 2n;
  }

  // Build a FULLY SIGNED op for a given gas set (both signatures valid).
  const buildOp = async (g: {
    verif: bigint; call: bigint; preVerif: bigint; pmVerif: bigint; pmPost: bigint;
  }): Promise<any> => {
    const accountGasLimits = packAccountGasLimits(g.verif, g.call);
    const gasFees = packGasFees(maxPrio, maxFee);
    const digest = sponsorshipDigest({
      paymaster: PAYMASTER,
      chainId: network.chainId,
      sender,
      nonce,
      initCode,
      callData,
      accountGasLimits,
      preVerificationGas: g.preVerif,
      gasFees,
      verificationGasLimit: g.pmVerif,
      postOpGasLimit: g.pmPost,
      validUntil,
      validAfter,
      opType: OP_REGISTER,
    });
    const pmSig = await signSponsorship(deployer, digest);
    const paymasterAndData = buildPaymasterAndData(
      PAYMASTER, g.pmVerif, g.pmPost, validUntil, validAfter, OP_REGISTER, pmSig
    );
    const op: any = {
      sender,
      nonce: ethers.toBeHex(nonce),
      initCode,
      callData,
      accountGasLimits,
      preVerificationGas: ethers.toBeHex(g.preVerif),
      gasFees,
      paymasterAndData,
      signature: "0x",
    };
    const uoHash: string = await entrypoint.getUserOpHash(op);
    op.signature = await ownerSigner.signMessage(ethers.getBytes(uoHash));
    return op;
  };

  // Pimlico's v2 endpoint expects the v0.8-style JSON layout (unpacked gas
  // fields, factory/factoryData, split paymaster fields) even though the
  // on-chain EntryPoint is v0.7. Convert the internal packed op for RPC.
  const toPimlicoOp = (op: any) => {
    const init = ethers.getBytes(op.initCode);
    const agl = BigInt(op.accountGasLimits);
    const gf = BigInt(op.gasFees);
    const pmd = ethers.getBytes(op.paymasterAndData);
    const MASK128 = (1n << 128n) - 1n;
    return {
      sender: op.sender,
      nonce: op.nonce,
      factory: ethers.hexlify(init.slice(0, 20)),
      factoryData: ethers.hexlify(init.slice(20)),
      callData: op.callData,
      callGasLimit: ethers.toBeHex(agl & MASK128),
      verificationGasLimit: ethers.toBeHex(agl >> 128n),
      preVerificationGas: op.preVerificationGas,
      maxPriorityFeePerGas: ethers.toBeHex(gf >> 128n),
      maxFeePerGas: ethers.toBeHex(gf & MASK128),
      paymaster: ethers.hexlify(pmd.slice(0, 20)),
      paymasterVerificationGasLimit: ethers.toBeHex(BigInt(ethers.hexlify(pmd.slice(20, 36)))),
      paymasterPostOpGasLimit: ethers.toBeHex(BigInt(ethers.hexlify(pmd.slice(36, 52)))),
      paymasterData: ethers.hexlify(pmd.slice(52)),
      signature: op.signature,
    };
  };

  // 9. Build the fully-signed op with generous manual gas limits.
  // NOTE: we do NOT call eth_estimateUserOperationGas. Pimlico's estimator
  // replaces maxFeePerGas/maxPriorityFeePerGas/preVerificationGas and all gas
  // limits with simulation values before validating, which would invalidate
  // our paymaster signature (the digest commits to the gas values).
  // eth_sendUserOperation validates with our values intact.
  console.log("building sponsored op (manual gas, no Pimlico estimation)...");
  let op = await buildOp({ verif: 1_500_000n, call: 2_000_000n, preVerif: 200_000n, pmVerif: 500_000n, pmPost: 200_000n });
  console.log("signed: paymaster + account signatures OK");

  // 11. submit
  console.log("submitting...");
  let userOpHash: string;
  try {
    userOpHash = await pimlico("eth_sendUserOperation", [toPimlicoOp(op), ENTRYPOINT]);
  } catch (e) {
    fail(`submission failed: ${(e as Error).message}`);
  }
  console.log(`sent: ${userOpHash!}`);

  // 12. poll for receipt (2 min)
  const deadline = Date.now() + 120_000;
  let receipt: any = null;
  while (Date.now() < deadline) {
    receipt = await pimlico("eth_getUserOperationReceipt", [userOpHash!]);
    if (receipt) break;
    await new Promise((r) => setTimeout(r, 5000));
  }
  if (!receipt) fail(`no receipt after 2 min (hash ${userOpHash!})`);
  if (receipt.success !== true) fail("user op reverted on-chain");
  console.log("mined: success=true");

  // 13. verify outcome on-chain
  const finalOwner: string = await registry.owner(node);
  if (finalOwner.toLowerCase() !== sender.toLowerCase())
    fail(`registry owner ${short(finalOwner)} != account`);
  const depositAfter: bigint = await paymaster.depositBalance();
  if (!(depositAfter < depositBefore))
    fail(`deposit did not decrease (${ethers.formatEther(depositBefore)} -> ${ethers.formatEther(depositAfter)})`);
  console.log(`owner: ${short(finalOwner)} OK`);
  console.log(`deposit: ${ethers.formatEther(depositBefore)} -> ${ethers.formatEther(depositAfter)} (sponsored)`);

  fs.writeFileSync(
    path.join(__dirname, "..", "deployments", "paymaster-proof.json"),
    JSON.stringify(
      { label: `${label}.arc`, node, sender, userOpHash, receiptBlock: receipt.receipt?.blockNumber,
        depositBefore: depositBefore.toString(), depositAfter: depositAfter.toString(),
        timestamp: new Date().toISOString() },
      null, 2
    )
  );
  console.log(`PAYMASTER PROOF: PASS — sponsored user op ${userOpHash!} registered ${label}.arc`);
}

main().catch((e) => {
  console.log(`PAYMASTER PROOF: FAIL — ${e?.message ?? e}`);
  process.exit(1);
});
