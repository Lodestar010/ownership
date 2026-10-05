/** Top up the paymaster's EntryPoint deposit (testnet). */
import { ethers } from "hardhat";

const PAYMASTER = "0xcd629172f31d9a25279Ac5fAB333312dC63De67c";
const TOPUP = ethers.parseEther("1.0"); // add 1 USDC -> 2.0 total

async function main() {
  const key = process.env.DEPLOYER_KEY;
  if (!key) { console.log("TOPUP FAIL - DEPLOYER_KEY not set"); process.exit(1); }
  const provider = ethers.provider;
  const signer = new ethers.Wallet(key, provider);
  const pm = new ethers.Contract(PAYMASTER, [
    "function deposit() payable",
    "function depositBalance() view returns (uint256)",
  ], signer);
  const before: bigint = await pm.depositBalance();
  console.log(`deposit before: ${ethers.formatEther(before)} USDC`);
  const tx = await pm.deposit({ value: TOPUP });
  await tx.wait();
  const after: bigint = await pm.depositBalance();
  console.log(`deposit after: ${ethers.formatEther(after)} USDC`);
  console.log("TOPUP DONE");
}
main().catch((e) => { console.error("TOPUP ERROR:", (e as Error).message); process.exit(1); });
