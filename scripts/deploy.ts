/**
 * Testnet deployment for the .arc naming service (Arc Testnet, chain 5042002).
 *
 * Run (Douglas signs from his own wallet; the key is NEVER committed):
 *   DEPLOYER_KEY=0x... npx hardhat run scripts/deploy.ts --network arcTestnet
 *
 * Phases:
 *   1. Deploy the 7-day TimelockController, then all 9 UUPS proxies with
 *      admin = the deployer (Douglas) so wiring stays fast on testnet.
 *   2. Wire everything: controllers, allowlists, paymaster target allowlist,
 *      splitter wallets, reverse root, sample brand reservations.
 *   3. Hand DEFAULT_ADMIN_ROLE on every proxy to the timelock (grant, then
 *      renounce). After this, changes go through the 7-day timelock; the
 *      guardian (Douglas) keeps instant tighten/pause powers on the Paymaster.
 *
 * Addresses are written to deployments/arc-testnet.json.
 */
import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const ENTRYPOINT_V07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"; // canonical, verified live 2026-10-01
const TIMELOCK_DELAY = 7 * 24 * 3600;

// ---- PLACEHOLDERS (testnet only; revisit before mainnet) ----
const SPLIT_BPS = { sponsor: 5000, treasury: 3000, security: 2000 }; // PLACEHOLDER ratios
const SAMPLE_RESERVED = ["acme", "globex", "initech", "umbrella", "stark"]; // fictional demo brands
// Paymaster degradation thresholds, in native-token wei. Native balances on Arc are
// 18-decimal (verified live: 140 testnet USDC = 1.4e20). 5 / 1 USDC.
const LOW_THRESHOLD = process.env.PAYMASTER_LOW_THRESHOLD ?? "5000000000000000000";
const CRITICAL_THRESHOLD = process.env.PAYMASTER_CRITICAL_THRESHOLD ?? "1000000000000000000";
// Placeholder tier prices (testnet USDC, 18 decimals) + outsider matching fee.
// Set AFTER the vault seeds its reserved names (see phase 2 ordering note).
const TIER_PRICES: Record<number, string> = { 3: "50000000000000000", 4: "40000000000000000", 5: "30000000000000000", 6: "20000000000000000" };
const MATCHING_FEE = "10000000000000000";
// Paymaster EntryPoint stake (ERC-7562: bundlers only accept validation-phase
// storage writes from staked paymasters). 1 USDC.
const PAYMASTER_STAKE = "1000000000000000000";
const STAKE_DELAY_SECS = 86400; // 1 day unstake delay

async function deployProxy(label: string, factory: string, initCalldata: string) {
  const impl = await (await ethers.getContractFactory(factory)).deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  const proxy = await (await ethers.getContractFactory("ERC1967Proxy")).deploy(implAddr, initCalldata);
  await proxy.waitForDeployment();
  const proxyAddr = await proxy.getAddress();
  console.log(`  ${label}: impl ${implAddr} -> proxy ${proxyAddr}`);
  return { impl: implAddr, proxy: proxyAddr };
}

function merkleRoot(leaves: string[]): string {
  // Simple sorted-pair Merkle root (transparency commitment only; nothing verifies it on-chain).
  let level = leaves
    .map((l) => ethers.keccak256(ethers.toUtf8Bytes(l)))
    .sort((a, b) => (a < b ? -1 : 1));
  while (level.length > 1) {
    const next: string[] = [];
    for (let i = 0; i < level.length; i += 2) {
      const a = level[i];
      const b = i + 1 < level.length ? level[i + 1] : level[i];
      const [x, y] = a < b ? [a, b] : [b, a];
      next.push(ethers.keccak256(ethers.concat([x, y])));
    }
    level = next;
  }
  return level[0];
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddr = await deployer.getAddress();
  console.log(`Deployer: ${deployerAddr}`);
  console.log(`Network chainId: ${(await ethers.provider.getNetwork()).chainId}`);

  const out: Record<string, any> = { deployer: deployerAddr, contracts: {} };

  // ---------- Phase 1: deploy ----------
  console.log("\n[1/3] Deploying TimelockController (7-day)...");
  const timelock = await (await ethers.getContractFactory("TimelockController")).deploy(
    TIMELOCK_DELAY,
    [deployerAddr], // proposers
    [deployerAddr], // executors
    deployerAddr // admin (renounced below so only the timelock itself administers)
  );
  await timelock.waitForDeployment();
  const timelockAddr = await timelock.getAddress();
  out.contracts.timelock = timelockAddr;
  console.log(`  TimelockController: ${timelockAddr}`);

  console.log("\n[1/3] Deploying proxies (admin = deployer for now)...");
  const deploy = async (label: string, factory: string, args: any[]) => {
    const c = await ethers.getContractFactory(factory);
    const data = c.interface.encodeFunctionData("initialize", args);
    const r = await deployProxy(label, factory, data);
    out.contracts[label] = r;
    return r.proxy;
  };

  const registry = await deploy("Registry", "Registry", [deployerAddr]);
  // Splitter before Registrar (registrar takes the splitter address at init).
  // PLACEHOLDER: all three purpose-wallets = deployer on testnet. The wallet-role map
  // says Douglas assigns a dedicated treasury wallet per build — do that before mainnet.
  const splitter = await deploy("Splitter", "Splitter", [
    deployerAddr,
    deployerAddr,
    deployerAddr,
    deployerAddr,
    SPLIT_BPS.sponsor,
    SPLIT_BPS.treasury,
    SPLIT_BPS.security,
  ]);
  const registrar = await deploy("Registrar", "Registrar", [deployerAddr, registry, splitter]);
  const resolver = await deploy("Resolver", "Resolver", [deployerAddr, registry]);
  const reverseRegistrar = await deploy("ReverseRegistrar", "ReverseRegistrar", [
    deployerAddr,
    registry,
    resolver,
  ]);
  const brandVault = await deploy("BrandVault", "BrandVault", [deployerAddr, registry, registrar, splitter]);
  const marketplace = await deploy("Marketplace", "Marketplace", [deployerAddr, registry, registrar, splitter]);
  // AttestationRegistry: admin = deployer (testnet); issuer = deployer (the education
  // program doesn't exist yet — mainnet issuer is the family office).
  const attestations = await deploy("AttestationRegistry", "AttestationRegistry", [deployerAddr, deployerAddr]);
  // Paymaster: guardian = deployer (instant tighten/pause); verifying signer = deployer
  // on testnet (the demo signing service uses this key — mainnet gets hardened signer infra).
  const paymaster = await deploy("Paymaster", "ArcPaymaster", [
    deployerAddr,
    deployerAddr,
    ENTRYPOINT_V07,
    deployerAddr,
    deployerAddr, // vault: ONLY withdrawal destination (testnet = deployer)
    LOW_THRESHOLD,
    CRITICAL_THRESHOLD,
  ]);

  // ---------- Phase 2: wire ----------
  console.log("\n[2/3] Wiring...");
  const registryC = await ethers.getContractAt("Registry", registry);
  const registrarC = await ethers.getContractAt("Registrar", registrar);
  const resolverC = await ethers.getContractAt("Resolver", resolver);
  const reverseRegistrarC = await ethers.getContractAt("ReverseRegistrar", reverseRegistrar);
  const brandVaultC = await ethers.getContractAt("BrandVault", brandVault);
  const paymasterC = await ethers.getContractAt("ArcPaymaster", paymaster);
  const attestationsC = await ethers.getContractAt("AttestationRegistry", attestations);

  console.log("  - registrar as registry controller");
  await (await registryC.setController(registrar, true)).wait();

  console.log("  - registrar <-> resolver activity hook");
  await (await registrarC.setNotifier(resolver, true)).wait();
  await (await resolverC.setRegistrar(registrar)).wait();
  console.log("  - marketplace authorized in registrar (sale term/hold-clock resets)");
  await (await registrarC.setMarketplace(marketplace)).wait();

  console.log("  - brandVault wired in registrar (park exemption + acquisition hook)");
  await (await registrarC.setBrandVault(brandVault)).wait();

  console.log("  - brandVault allowlisted in registrar (free seeding)");
  await (await registrarC.setAllowlisted(brandVault, true)).wait();

  console.log("  - deployer allowlisted in registrar (family/fee-exempt test names)");
  await (await registrarC.setAllowlisted(deployerAddr, true)).wait();

  console.log("  - attestation registry wired; deployer attested for orientation (track 0)");
  await (await registrarC.setAttestationRegistry(attestations)).wait();
  await (await attestationsC.attest(deployerAddr, 0)).wait();

  console.log("  - granting reverse root to the ReverseRegistrar");
  const ROOT = "0x" + "00".repeat(32);
  await (await registryC.setController(deployerAddr, true)).wait(); // temporary
  await (await registryC.setSubnodeOwner(ROOT, ethers.keccak256(ethers.toUtf8Bytes("reverse")), reverseRegistrar)).wait();
  await (await registryC.setController(deployerAddr, false)).wait();

  console.log("  - reverse root resolver (so registry -> resolver resolves reverse names)");
  await (await reverseRegistrarC.setReverseRootResolver()).wait();

  console.log("  - brandVault default resolver (for org-mark attestation)");
  await (await brandVaultC.setDefaultResolver(resolver)).wait();

  console.log("  - seeding sample reserved names to the vault");
  await (await brandVaultC.reserveLabels(SAMPLE_RESERVED)).wait();
  const root = merkleRoot(SAMPLE_RESERVED);
  await (await brandVaultC.setMerkleRoot(root)).wait();
  console.log(`    merkle root: ${root}`);

  // ORDERING: tier prices + matching fee go live AFTER seeding. reserveLabels ->
  // registrar.register from the vault with no value, and the vault is
  // allowlisted-but-unattested (not family-free), so seeding with prices set
  // would revert InsufficientPayment.
  console.log("  - placeholder tier prices + matching fee (after seeding)");
  for (const len of [3, 4, 5, 6]) {
    await (await registrarC.setTierPrice(len, TIER_PRICES[len])).wait();
    console.log(`    tier[${len}] = ${TIER_PRICES[len]}`);
  }
  await (await registrarC.setMatchingFee(MATCHING_FEE)).wait();
  console.log(`    matchingFee = ${MATCHING_FEE}`);

  console.log("  - paymaster target/selector allowlist");
  const allow = async (target: string, contractName: string, fn: string, opType: number) => {
    const iface = (await ethers.getContractFactory(contractName)).interface;
    const sel = iface.getFunction(fn)!.selector;
    await (await paymasterC.setTargetAllowed(target, sel, opType)).wait();
    console.log(`    ${contractName}.${fn} (${sel}) -> opType ${opType}`);
  };
  const OP = { REGISTER: 1, RENEW: 2, RECORD: 3, SUBNAME: 4 };
  await allow(registrar, "Registrar", "register(string,address)", OP.REGISTER);
  await allow(registrar, "Registrar", "renew(string)", OP.RENEW);
  await allow(registrar, "Registrar", "registerSubname(bytes32,string,address)", OP.SUBNAME);
  await allow(resolver, "Resolver", "setAddr(bytes32,address)", OP.RECORD);
  await allow(resolver, "Resolver", "setText(bytes32,string,string)", OP.RECORD);
  await allow(resolver, "Resolver", "setContenthash(bytes32,bytes)", OP.RECORD);
  await allow(reverseRegistrar, "ReverseRegistrar", "setName(string)", OP.RECORD);

  console.log("  - deployer on paymaster Sybil allowlist (higher caps)");
  await (await paymasterC.setSybilAllowlisted(deployerAddr, true)).wait();

  console.log("  - funding paymaster EntryPoint deposit + stake (ERC-7562)");
  const epCode = await ethers.provider.getCode(ENTRYPOINT_V07);
  if (epCode === "0x") {
    // Local dry-run: the canonical EntryPoint has no code here, so depositTo/addStake
    // would revert on the non-contract call. Skip funding; on testnet/mainnet the
    // EntryPoint exists and this path runs.
    console.log("    (skipped: no EntryPoint code on this network — dry-run only)");
  } else {
    await (await paymasterC.deposit({ value: ethers.parseEther("1") })).wait();
    await (await paymasterC.stake(STAKE_DELAY_SECS, { value: PAYMASTER_STAKE })).wait();
    console.log(`    deposit 1 USDC + stake ${PAYMASTER_STAKE} wei (${STAKE_DELAY_SECS}s delay)`);
  }

  // ---------- Phase 3: hand admin to the timelock ----------
  console.log("\n[3/3] Handing DEFAULT_ADMIN_ROLE to the timelock...");
  const ADMIN_ROLE = "0x" + "00".repeat(32);
  for (const label of ["Registry", "Registrar", "Resolver", "ReverseRegistrar", "BrandVault", "Marketplace", "Splitter", "Paymaster", "AttestationRegistry"]) {
    const c = await ethers.getContractAt(
      label === "Paymaster" ? "ArcPaymaster" : label,
      out.contracts[label].proxy
    );
    await (await c.grantRole(ADMIN_ROLE, timelockAddr)).wait();
    await (await c.renounceRole(ADMIN_ROLE, deployerAddr)).wait();
    console.log(`  - ${label}: admin -> timelock`);
  }
  // Timelock renounces its own admin so only timelock proposals can administer it.
  // (OZ v5: the timelock grants itself DEFAULT_ADMIN_ROLE at construction.)
  const timelockC = await ethers.getContractAt("TimelockController", timelockAddr);
  await (await timelockC.renounceRole(ADMIN_ROLE, deployerAddr)).wait();
  console.log("  - timelock self-admin renounced (proposals only from here on)");

  const dest = path.join(__dirname, "..", "deployments", "arc-testnet.json");
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, JSON.stringify(out, null, 2));
  console.log(`\nDeployment record: ${dest}`);
  console.log("\nDone. Next: run the testnet checklist (first proving the paymaster against a live bundler).");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
