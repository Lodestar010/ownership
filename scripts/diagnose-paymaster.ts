/**
 * Diagnostic: build the EXACT sponsored op like test-paymaster-bundler.ts,
 * but simulate DIRECTLY against the live EntryPoint (eth_call, no Pimlico).
 * - BadSignature on direct call  => our op construction is wrong
 * - Anything else (or pass)      => our op is fine, Pimlico altered it
 */
import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import {
  sponsorshipDigest,
  buildPaymasterAndData,
  signSponsorship,
  recoverSponsorshipSigner,
  packAccountGasLimits,
  packGasFees,
} from "./sponsor-digest";

const PAYMASTER = "0xcd629172f31d9a25279Ac5fAB333312dC63De67c";
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const REGISTRAR = "0xb8351Bcc980dA96b091C42092b8d53A7C647E35b";
const REGISTRY = "0x523553fC7fC78F97386F0740847d9E594119D8Bb";
const EXPECTED_CHAIN_ID = 5042002;
const OP_REGISTER = 1;

const short = (a: string) => a.slice(0, 6) + "..." + a.slice(-4);
const fail = (m: string): never => { console.log(`DIAG FAIL - ${m}`); process.exit(1); };
const nodeForLabel = (label: string) =>
  ethers.keccak256(ethers.concat([
    ethers.keccak256(ethers.toUtf8Bytes("arc")),
    ethers.keccak256(ethers.toUtf8Bytes(label)),
  ]));

async function main() {
  const key = process.env.DEPLOYER_KEY;
  if (!key) fail("DEPLOYER_KEY not set in env");
  const provider = ethers.provider;
  const net = await provider.getNetwork();
  if (net.chainId !== BigInt(EXPECTED_CHAIN_ID)) fail(`wrong chain: ${net.chainId}`);
  const deployer = new ethers.Wallet(key!, provider);
  console.log(`deployer: ${short(deployer.address)}`);

  const paymaster = new ethers.Contract(PAYMASTER, [
    "function verifyingSigner() view returns (address)",
  ], provider);
  const vs: string = await paymaster.verifyingSigner();
  if (vs.toLowerCase() !== deployer.address.toLowerCase()) fail("signer != deployer");
  console.log("verifying signer: OK");

  const entrypoint = new ethers.Contract(ENTRYPOINT, [
    "function getNonce(address,uint192) view returns (uint256)",
    "function simulateValidation((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes))",
    "function getUserOpHash((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)) view returns (bytes32)",
  ], provider);
  const registry = new ethers.Contract(REGISTRY, ["function owner(bytes32) view returns (address)"], provider);
  const registrar = new ethers.Contract(REGISTRAR, ["function matchingFee() view returns (uint256)"], provider);
  const registrarIface = new ethers.Interface(["function register(string,address)"]);

  // 1. factory (deploy fresh, like the main script)
  const aa = JSON.parse(fs.readFileSync(path.join(__dirname, "aa-artifacts.json"), "utf8"));
  const factory = await (
    await new ethers.ContractFactory(aa.factoryAbi, aa.factoryBytecode, deployer).deploy(ENTRYPOINT)
  ).waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log(`factory: ${short(factoryAddr)}`);

  // 2. fresh account
  const owner = ethers.Wallet.createRandom();
  const ownerSigner = owner.connect(provider);
  const salt = ethers.hexlify(ethers.randomBytes(32));
  const sender: string = await factory.getFunction("getAddress")(owner.address, salt);
  console.log(`account: ${short(sender)} (counterfactual)`);

  // 3. name + calldata (same as main script)
  const rand = [...ethers.randomBytes(4)].map((b) => "0123456789abcdef"[b % 16]).join("");
  const label = `diag-proof-${rand}`;
  const node = nodeForLabel(label);
  if ((await registry.owner(node)) !== ethers.ZeroAddress) fail(`name collision: ${label}`);
  const matchingFee: bigint = await registrar.matchingFee();
  const inner = registrarIface.encodeFunctionData("register", [label, sender]);
  const accountIface = new ethers.Interface(aa.accountAbi);
  const callData = accountIface.encodeFunctionData("execute", [REGISTRAR, matchingFee, inner]);

  // 4. initCode + digest + signatures (same as main script)
  const initCode =
    factoryAddr + factory.interface.encodeFunctionData("createAccount", [owner.address, salt]).slice(2);
  const nonce: bigint = await entrypoint.getNonce(sender, 0);
  const now = (await provider.getBlock("latest"))!.timestamp;
  const validUntil = now + 3600;
  const validAfter = now - 300;
  const maxFee = ethers.parseUnits("2", "gwei");
  const maxPrio = ethers.parseUnits("1", "gwei");
  const verif = 600000n, call = 1200000n, preVerif = 120000n, pmVerif = 200000n, pmPost = 100000n;
  const accountGasLimits = packAccountGasLimits(verif, call);
  const gasFees = packGasFees(maxPrio, maxFee);
  const digest = sponsorshipDigest({
    paymaster: PAYMASTER, chainId: BigInt(EXPECTED_CHAIN_ID), sender, nonce, initCode, callData,
    accountGasLimits, preVerificationGas: preVerif, gasFees,
    verificationGasLimit: pmVerif, postOpGasLimit: pmPost,
    validUntil, validAfter, opType: OP_REGISTER,
  });
  const pmSig = await signSponsorship(deployer, digest);
  const recovered = recoverSponsorshipSigner(digest, pmSig);
  console.log(`digest: ${digest.slice(0, 18)}...`);
  console.log(`sig recovers to signer: ${recovered.toLowerCase() === vs.toLowerCase() ? "OK" : "MISMATCH"}`);
  if (recovered.toLowerCase() !== vs.toLowerCase()) fail("local sig recovery failed");

  const paymasterAndData = buildPaymasterAndData(PAYMASTER, pmVerif, pmPost, validUntil, validAfter, OP_REGISTER, pmSig);
  const packedOp: any = [sender, nonce, initCode, callData, accountGasLimits, preVerif, gasFees, paymasterAndData, "0x"];
  const uoHash: string = await entrypoint.getUserOpHash(packedOp);
  packedOp[8] = await ownerSigner.signMessage(ethers.getBytes(uoHash));
  console.log(`userOpHash: ${uoHash.slice(0, 18)}...`);

  // 5. DIRECT simulateValidation via eth_call (no Pimlico)
  console.log("simulating directly against EntryPoint (no Pimlico)...");
  try {
    await entrypoint.simulateValidation.staticCall(packedOp);
    console.log("DIAG RESULT: no revert — paymaster ACCEPTED the op. Pimlico is altering it.");
  } catch (e: any) {
    const msg: string = e?.message ?? String(e);
    const hex = (msg.match(/0x[0-9a-fA-F]{8,}/) ?? [])[0] ?? "";
    if (hex.startsWith("0x5cd5d233") || msg.includes("BadSignature")) {
      console.log("DIAG RESULT: BadSignature on DIRECT call — our op construction is wrong.");
    } else if (msg.includes("AA23") || msg.includes("AA24")) {
      console.log("DIAG RESULT: account validation failed, paymaster not reached. Inconclusive for paymaster.");
    } else {
      console.log(`DIAG RESULT: reverted with: ${hex ? hex.slice(0, 18) + "..." : msg.slice(0, 160)}`);
      console.log("(not BadSignature — paymaster signature path was passed or not reached)");
    }
  }
}

main().catch((e) => { console.error("DIAG ERROR:", (e as Error).message); process.exit(1); });
