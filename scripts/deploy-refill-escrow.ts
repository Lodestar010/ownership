/**
 * RefillEscrow + RegionalWallets deployment (Arc Testnet, chain 5042002).
 *
 * Run (Douglas signs from his own wallet; the key is NEVER committed):
 *   DEPLOYER_KEY=0x... npx hardhat run scripts/deploy-refill-escrow.ts --network arcTestnet
 *
 * Deploys:
 *   1. RefillEscrow (UUPS proxy) — the programmed reserve wallet (#4)
 *   2. Three RegionalWallet contracts (USA, Europe, Asia/Africa)
 *   3. Registers regionals with TEMPORARY testnet seed caps
 *   4. Funds the escrow (DJ sets the amount via ESCROW_FUND env or default)
 *
 * Admin is the deployer (Douglas) for fast testnet iteration.
 * Mainnet: hand DEFAULT_ADMIN_ROLE to the timelock after wiring.
 *
 * ALL numeric values are TEMPORARY testnet placeholders.
 * Real allocations deferred until post-grant + post-audit.
 */
import { ethers } from "hardhat";

// TEMPORARY testnet seeds (18 decimals — Arc native USDC)
const SEED_USA = ethers.parseUnits("1250", 18);
const SEED_EU = ethers.parseUnits("2500", 18);
const SEED_ASIA = ethers.parseUnits("5000", 18);
const ESCROW_FUND = process.env.ESCROW_FUND ?? ethers.parseUnits("20000", 18).toString();

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

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddr = await deployer.getAddress();
  console.log(`Deployer: ${deployerAddr}`);
  console.log(`Network chainId: ${(await ethers.provider.getNetwork()).chainId}`);

  // Treasury address — DJ sets this. Defaults to deployer for testnet.
  const treasury = process.env.TREASURY ?? deployerAddr;
  // Splitter address — zero for now (Splitter upgrade adds fundEscrow later).
  const splitter = process.env.SPLITTER ?? ethers.ZeroAddress;

  console.log(`\nTreasury: ${treasury}`);
  console.log(`Splitter: ${splitter} ${splitter === ethers.ZeroAddress ? "(not set — manual funding)" : ""}`);

  // ---------- 1. Deploy RefillEscrow ----------
  console.log("\n[1/4] Deploying RefillEscrow...");
  const escrowFactory = await ethers.getContractFactory("RefillEscrow");
  const escrowInit = escrowFactory.interface.encodeFunctionData("initialize", [
    deployerAddr,
    treasury,
    splitter,
  ]);
  const { proxy: escrowAddr } = await deployProxy("RefillEscrow", "RefillEscrow", escrowInit);
  const escrow = escrowFactory.attach(escrowAddr);

  // ---------- 2. Deploy RegionalWallets ----------
  console.log("\n[2/4] Deploying RegionalWallets...");
  const rwFactory = await ethers.getContractFactory("RegionalWallet");
  const rwUSA = await rwFactory.deploy(escrowAddr, deployerAddr);
  await rwUSA.waitForDeployment();
  const usaAddr = await rwUSA.getAddress();
  console.log(`  USA: ${usaAddr}`);

  const rwEU = await rwFactory.deploy(escrowAddr, deployerAddr);
  await rwEU.waitForDeployment();
  const euAddr = await rwEU.getAddress();
  console.log(`  Europe: ${euAddr}`);

  const rwAsia = await rwFactory.deploy(escrowAddr, deployerAddr);
  await rwAsia.waitForDeployment();
  const asiaAddr = await rwAsia.getAddress();
  console.log(`  Asia/Africa: ${asiaAddr}`);

  // ---------- 3. Register regionals ----------
  console.log("\n[3/4] Registering regionals with TEMPORARY testnet seeds...");
  await (await escrow.registerRegional(0, usaAddr, SEED_USA)).wait();
  console.log(`  USA registered: 1,250 USDC seed`);
  await (await escrow.registerRegional(1, euAddr, SEED_EU)).wait();
  console.log(`  Europe registered: 2,500 USDC seed`);
  await (await escrow.registerRegional(2, asiaAddr, SEED_ASIA)).wait();
  console.log(`  Asia/Africa registered: 5,000 USDC seed`);

  // ---------- 4. Fund escrow ----------
  console.log(`\n[4/4] Funding escrow with ${ethers.formatUnits(ESCROW_FUND, 18)} USDC...`);
  await (await deployer.sendTransaction({ to: escrowAddr, value: ESCROW_FUND })).wait();
  console.log(`  Escrow funded.`);

  // Fund regionals to their seed caps
  console.log(`\nFunding regionals to seed caps...`);
  await (await deployer.sendTransaction({ to: usaAddr, value: SEED_USA })).wait();
  await (await deployer.sendTransaction({ to: euAddr, value: SEED_EU })).wait();
  await (await deployer.sendTransaction({ to: asiaAddr, value: SEED_ASIA })).wait();
  console.log(`  All regionals funded.`);

  // ---------- Summary ----------
  console.log("\n=== DEPLOYMENT COMPLETE ===");
  console.log(`RefillEscrow: ${escrowAddr}`);
  console.log(`USA:          ${usaAddr}`);
  console.log(`Europe:       ${euAddr}`);
  console.log(`Asia/Africa:  ${asiaAddr}`);
  console.log(`\nAll values TEMPORARY testnet placeholders.`);
  console.log(`Admin is deployer (${deployerAddr}) — hand to timelock before mainnet.`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
