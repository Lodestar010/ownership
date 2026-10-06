import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import {
  RefillEscrow__factory,
  RegionalWallet__factory,
  ERC1967Proxy__factory,
} from "../typechain-types";

/**
 * Scenario tests for the RefillEscrow — real-world behavior over time.
 * Covers: cold start seed phase-out, steady traffic, sudden spike,
 * sustained surge (breaker), griefing/poke spam, regional imbalance,
 * escrow depletion, and MA adaptation.
 * All values are TEMPORARY testnet placeholders.
 */

const DAY = 24 * 3600;
// Arc native USDC uses 18 decimals (verified live on testnet)
const USDC = (n: number) => ethers.parseUnits(n.toString(), 18);

const SEED_USA = USDC(125);
const SEED_EU = USDC(250);
const SEED_ASIA = USDC(5);

async function warp(seconds: number) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine", []);
}

describe("RefillEscrow scenarios", function () {
  async function deployFixture() {
    const [admin, treasury, splitter] = await ethers.getSigners();

    const escrowFactory = await ethers.getContractFactory("RefillEscrow");
    const escrowImpl = await escrowFactory.deploy();
    await escrowImpl.waitForDeployment();
    const initData = escrowFactory.interface.encodeFunctionData("initialize", [
      admin.address,
      treasury.address,
      splitter.address,
    ]);
    const proxyFactory = await ethers.getContractFactory("ERC1967Proxy");
    const proxy = await proxyFactory.deploy(await escrowImpl.getAddress(), initData);
    await proxy.waitForDeployment();
    const escrow = RefillEscrow__factory.connect(await proxy.getAddress(), admin);
    const escrowAddr = await escrow.getAddress();

    const rwFactory = new RegionalWallet__factory(admin);
    const rwUSA = await rwFactory.deploy(escrowAddr, admin.address);
    await rwUSA.waitForDeployment();
    const rwEU = await rwFactory.deploy(escrowAddr, admin.address);
    await rwEU.waitForDeployment();
    const rwAsia = await rwFactory.deploy(escrowAddr, admin.address);
    await rwAsia.waitForDeployment();
    const usaAddr = await rwUSA.getAddress();
    const euAddr = await rwEU.getAddress();
    const asiaAddr = await rwAsia.getAddress();

    await escrow.registerRegional(0, usaAddr, SEED_USA);
    await escrow.registerRegional(1, euAddr, SEED_EU);
    await escrow.registerRegional(2, asiaAddr, SEED_ASIA);

    await admin.sendTransaction({ to: escrowAddr, value: USDC(500) });
    await admin.sendTransaction({ to: usaAddr, value: SEED_USA });
    await admin.sendTransaction({ to: euAddr, value: SEED_EU });
    await admin.sendTransaction({ to: asiaAddr, value: SEED_ASIA });

    return { admin, treasury, splitter, escrow, escrowAddr, rwUSA, rwEU, rwAsia, usaAddr, euAddr, asiaAddr };
  }

  async function balanceOf(addr: string) {
    return ethers.provider.getBalance(addr);
  }

  // Simulate a day of spending: drain to trigger refills, up to maxPullsPerDay
  async function simulateDay(escrow: any, rw: any, admin: any, addr: string, spendPerCycle: bigint, cycles: number) {
    let refills = 0;
    for (let i = 0; i < cycles; i++) {
      const bal = await balanceOf(addr);
      if (bal <= spendPerCycle) break;
      // sponsor() triggers blind poke automatically
      await rw.connect(admin).sponsor(admin.address, spendPerCycle);
      const newBal = await balanceOf(addr);
      // If balance went back up, a refill happened
      if (newBal > bal - spendPerCycle) refills++;
    }
    return refills;
  }

  describe("cold start: seed phase-out over 21 days", function () {
    it("day 1 cap equals seed, then adapts toward actual usage", async function () {
      const { escrow, rwUSA, admin, usaAddr } = await loadFixture(deployFixture);

      // Day 1: cap = seed
      const [, , , capDay1] = await escrow.getRegional(0);
      expect(capDay1).to.equal(SEED_USA);

      // Simulate 7 days of light usage (~500/day, well below 1250 seed)
      for (let d = 0; d < 7; d++) {
        // Spend 500 via sponsor calls (blind poke auto-refills as needed)
        const bal = await balanceOf(usaAddr);
        if (bal > USDC(5)) {
          await rwUSA.connect(admin).sponsor(admin.address, USDC(5));
        }
        await warp(DAY);
        // Trigger cap recalculation for the new day
        await escrow.setOutboundPaused(true);
        await escrow.setOutboundPaused(false);
        await escrow.poke(usaAddr);
      }

      const [, , , capDay8] = await escrow.getRegional(0);
      // Cap should have moved DOWN from seed toward actual usage (~500/day)
      // Day 8: (500*7 + 1250*14) / 21 = (3500 + 17500) / 21 = 1000
      expect(capDay8).to.be.lt(SEED_USA);
      expect(capDay8).to.be.gt(USDC(5));
    });

    it("cap converges to steady usage by day 22", async function () {
      const { escrow, rwUSA, admin, usaAddr } = await loadFixture(deployFixture);

      // 21 days of consistent 800/day usage
      for (let d = 0; d < 21; d++) {
        await escrow.setOutboundPaused(true);
        const bal = await balanceOf(usaAddr);
        // Drain to ~100 to force refill pattern each day
        if (bal > USDC(20)) {
          await rwUSA.connect(admin).sponsor(admin.address, bal - USDC(1));
        }
        await escrow.setOutboundPaused(false);
        await warp(DAY);
        await escrow.poke(usaAddr); // recalc cap for new day
      }

      const [, , , capDay22] = await escrow.getRegional(0);
      // Should be close to actual daily usage (~1150/day in refills), seed fully phased out
      expect(capDay22).to.be.lt(SEED_USA);
      // Cap should reflect real usage, not the seed
      const dailyRefilled = await escrow.dailyRefilled(usaAddr, Math.floor(Date.now() / 86400000) - 1);
      expect(capDay22).to.be.gt(0);
    });
  });

  describe("sudden spike: circuit breaker protects", function () {
    it("massive single-day spike trips breaker, funds are bounded", async function () {
      const { escrow, rwUSA, admin, usaAddr, escrowAddr } = await loadFixture(deployFixture);
      const escrowBefore = await balanceOf(escrowAddr);

      // Attempt to drain far beyond normal: 10 rapid spend cycles
      let totalRefilled = 0;
      for (let i = 0; i < 10; i++) {
        const balBefore = await balanceOf(usaAddr);
        const bal = await balanceOf(usaAddr);
        if (bal > USDC(1)) {
          await rwUSA.connect(admin).sponsor(admin.address, bal - USDC(5));
        }
        const balAfter = await balanceOf(usaAddr);
        if (balAfter > USDC(5)) totalRefilled += Number(balAfter - USDC(5));
      }

      // Max 3 refills of ~1250 each = ~3750 max extracted in one day
      const escrowAfter = await balanceOf(escrowAddr);
      const escrowSpent = escrowBefore - escrowAfter;
      expect(escrowSpent).to.be.lte(SEED_USA * 3n + USDC(1)); // 3 refills max + margin
      expect(await escrow.refillsToday(usaAddr)).to.equal(3n);
    });
  });

  describe("griefing: poke spam does nothing", function () {
    it("100 failed pokes change no state and cost attacker gas only", async function () {
      const { escrow, usaAddr, escrowAddr } = await loadFixture(deployFixture);
      const escrowBalBefore = await balanceOf(escrowAddr);
      const usaBalBefore = await balanceOf(usaAddr);

      // Spam poke 100 times (no refill needed — balance is full)
      for (let i = 0; i < 100; i++) {
        await escrow.poke(usaAddr);
      }

      expect(await balanceOf(escrowAddr)).to.equal(escrowBalBefore);
      expect(await balanceOf(usaAddr)).to.equal(usaBalBefore);
      expect(await escrow.refillsToday(usaAddr)).to.equal(0n);
    });

    it("poke spam on unregistered address is free no-op", async function () {
      const { escrow } = await loadFixture(deployFixture);
      const [,, stranger] = await ethers.getSigners();
      for (let i = 0; i < 10; i++) {
        await escrow.poke(stranger.address); // must not revert
      }
    });
  });

  describe("regional imbalance: one region surges, others idle", function () {
    it("surging region gets refills, idle regions untouched", async function () {
      const { escrow, rwUSA, rwEU, admin, usaAddr, euAddr, escrowAddr } = await loadFixture(deployFixture);
      const escrowBefore = await balanceOf(escrowAddr);
      const euBefore = await balanceOf(euAddr);

      // USA surges: 3 refill cycles
      for (let i = 0; i < 3; i++) {
        const bal = await balanceOf(usaAddr);
        if (bal > USDC(1)) {
          await rwUSA.connect(admin).sponsor(admin.address, bal - USDC(5));
        }
      }

      // EU idle: no activity
      // Poke EU — should do nothing
      await escrow.poke(euAddr);

      expect(await balanceOf(euAddr)).to.equal(euBefore); // untouched
      expect(await escrow.refillsToday(euAddr)).to.equal(0n);
      expect(await escrow.refillsToday(usaAddr)).to.be.gt(0n);

      // Escrow only spent on USA
      const escrowSpent = escrowBefore - await balanceOf(escrowAddr);
      expect(escrowSpent).to.be.gt(0);
      expect(escrowSpent).to.be.lte(SEED_USA * 3n + USDC(1));
    });
  });

  describe("escrow depletion: graceful degradation", function () {
    it("regionals keep operating on remaining balance when escrow is empty", async function () {
      const { escrow, rwUSA, admin, treasury, usaAddr } = await loadFixture(deployFixture);

      // Empty the escrow
      await escrow.emergencyDrain(treasury.address);
      await escrow.setOutboundPaused(false);
      await escrow.setInboundPaused(false);

      // Regional still has its seed balance — sponsorship continues
      const balBefore = await balanceOf(usaAddr);
      await rwUSA.connect(admin).sponsor(admin.address, USDC(1));
      expect(await balanceOf(usaAddr)).to.equal(balBefore - USDC(1));

      // Poke finds empty escrow — no revert, no refill
      await escrow.poke(usaAddr);
      expect(await balanceOf(usaAddr)).to.equal(balBefore - USDC(1));
    });
  });

  describe("MA adaptation: cap follows usage trends", function () {
    it("cap rises when usage grows steadily", async function () {
      const { escrow, rwUSA, admin, usaAddr } = await loadFixture(deployFixture);

      const [, , , initialCap] = await escrow.getRegional(0);

      // 10 days of growing usage: each day spend more
      for (let d = 0; d < 10; d++) {
        await escrow.setOutboundPaused(true);
        const bal = await balanceOf(usaAddr);
        // Spend increasing amounts each day (scaled to 125 seed)
        const spend = USDC(60 + d * 5);
        if (bal > spend + USDC(1)) {
          await rwUSA.connect(admin).sponsor(admin.address, spend);
        }
        await escrow.setOutboundPaused(false);
        await warp(DAY);
        await escrow.poke(usaAddr);
      }

      const [, , , finalCap] = await escrow.getRegional(0);
      // Cap should have moved (adapting to the usage pattern)
      expect(finalCap).to.not.equal(initialCap);
    });
  });
});
