import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import {
  RefillEscrow__factory,
  RegionalWallet__factory,
  ERC1967Proxy__factory,
} from "../typechain-types";

/**
 * Unit tests for the RefillEscrow (sponsorship wallet #4).
 * Covers: registration, poke release conditions, circuit breaker,
 * pauses, emergency drain, dials, two-step rotation, and blind poke.
 * All values are TEMPORARY testnet placeholders.
 *
 * Regionals are RegionalWallet contracts (the real design), not EOAs —
 * this gives precise balance control and tests the blind poke integration.
 */

const DAY = 24 * 3600;
// Arc native USDC uses 18 decimals (verified live on testnet)
const USDC = (n: number) => ethers.parseUnits(n.toString(), 18);

// TEMPORARY testnet seeds
const SEED_USA = USDC(125);
const SEED_EU = USDC(250);
const SEED_ASIA = USDC(5);

async function warp(seconds: number) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine", []);
}

describe("RefillEscrow", function () {
  async function deployFixture() {
    const [admin, treasury, splitter, stranger] = await ethers.getSigners();

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

    return { admin, treasury, splitter, stranger, escrow, escrowAddr, rwUSA, rwEU, rwAsia, usaAddr, euAddr, asiaAddr };
  }

  async function balanceOf(addr: string) {
    return ethers.provider.getBalance(addr);
  }

  // Drain a regional to a target balance via sponsor() (admin is the wallet admin)
  async function drainTo(rw: any, admin: any, target: bigint) {
    const addr = await rw.getAddress();
    const bal = await balanceOf(addr);
    if (bal > target) {
      await rw.connect(admin).sponsor(admin.address, bal - target);
    }
  }

  describe("registration", function () {
    it("registers three regionals with seed caps", async function () {
      const { escrow, usaAddr, euAddr, asiaAddr } = await loadFixture(deployFixture);
      const [w0, , seed0, cap0] = await escrow.getRegional(0);
      const [w1] = await escrow.getRegional(1);
      const [w2] = await escrow.getRegional(2);
      expect(w0).to.equal(usaAddr);
      expect(w1).to.equal(euAddr);
      expect(w2).to.equal(asiaAddr);
      expect(seed0).to.equal(SEED_USA);
      expect(cap0).to.equal(SEED_USA);
    });

    it("rejects zero address and bad region", async function () {
      const { escrow } = await loadFixture(deployFixture);
      await expect(escrow.registerRegional(0, ethers.ZeroAddress, SEED_USA))
        .to.be.revertedWithCustomError(escrow, "ZeroAddress");
      await expect(escrow.registerRegional(3, ethers.ZeroAddress, SEED_USA))
        .to.be.revertedWithCustomError(escrow, "BadRegion");
    });

    it("only admin can register", async function () {
      const { escrow, stranger, usaAddr } = await loadFixture(deployFixture);
      await expect(escrow.connect(stranger).registerRegional(0, usaAddr, SEED_USA))
        .to.be.reverted;
    });
  });

  describe("poke — release conditions", function () {
    it("does nothing when balance is above trigger", async function () {
      const { escrow, usaAddr } = await loadFixture(deployFixture);
      const before = await balanceOf(usaAddr);
      await escrow.poke(usaAddr);
      expect(await balanceOf(usaAddr)).to.equal(before);
      expect(await escrow.needsRefill(usaAddr)).to.equal(false);
    });

    it("tops up to 100% of cap when balance is at/below 10%", async function () {
      const { escrow, rwUSA, admin, usaAddr } = await loadFixture(deployFixture);
      // Pause outbound so the drain doesn't auto-refill via blind poke
      await escrow.setOutboundPaused(true);
      await drainTo(rwUSA, admin, USDC(6.25)); // 5% of 1250
      await escrow.setOutboundPaused(false);

      expect(await escrow.needsRefill(usaAddr)).to.equal(true);
      await expect(escrow.poke(usaAddr)).to.emit(escrow, "RefillExecuted");
      expect(await balanceOf(usaAddr)).to.equal(SEED_USA);
    });

    it("exits silently for unregistered address", async function () {
      const { escrow, stranger } = await loadFixture(deployFixture);
      await escrow.poke(stranger.address); // must not revert
      expect(await escrow.needsRefill(stranger.address)).to.equal(false);
    });

    it("exits silently when escrow is empty", async function () {
      const { escrow, rwUSA, admin, treasury, usaAddr } = await loadFixture(deployFixture);
      await escrow.emergencyDrain(treasury.address);
      await drainTo(rwUSA, admin, USDC(1));

      await escrow.poke(usaAddr); // must not revert
      expect(await balanceOf(usaAddr)).to.equal(USDC(1));
    });

    it("partial refill when escrow cannot cover full top-up", async function () {
      const { escrow, rwUSA, admin, treasury, usaAddr } = await loadFixture(deployFixture);
      // Drain escrow to just 100 USDC
      await escrow.emergencyDrain(treasury.address);
      // Unpause (drain pauses both flows)
      await escrow.setOutboundPaused(false);
      await escrow.setInboundPaused(false);
      await admin.sendTransaction({ to: await escrow.getAddress(), value: USDC(10) });

      // Drain regional below trigger without auto-refill
      await escrow.setOutboundPaused(true);
      await drainTo(rwUSA, admin, USDC(1)); // needs ~1240 to top up
      await escrow.setOutboundPaused(false);

      await expect(escrow.poke(usaAddr)).to.emit(escrow, "EscrowDepleted");
      // Gets the full 100 the escrow had
      expect(await balanceOf(usaAddr)).to.equal(USDC(11));
    });
  });

  describe("circuit breaker", function () {
    it("trips on 4th refill attempt in one day", async function () {
      const { escrow, rwUSA, admin, usaAddr } = await loadFixture(deployFixture);

      for (let i = 0; i < 3; i++) {
        await drainTo(rwUSA, admin, USDC(5));
        await escrow.poke(usaAddr);
      }
      expect(await escrow.refillsToday(usaAddr)).to.equal(3n);

      await drainTo(rwUSA, admin, USDC(5));
      await expect(escrow.poke(usaAddr))
        .to.emit(escrow, "CircuitBreakerTripped")
        .withArgs(usaAddr, 3);

      expect(await balanceOf(usaAddr)).to.equal(USDC(5)); // no funds moved
      expect(await escrow.refillsToday(usaAddr)).to.equal(3n);
    });

    it("approveExtraPulls allows more refills after breaker", async function () {
      const { escrow, rwUSA, admin, usaAddr } = await loadFixture(deployFixture);

      for (let i = 0; i < 3; i++) {
        await drainTo(rwUSA, admin, USDC(5));
        await escrow.poke(usaAddr);
      }

      await escrow.approveExtraPulls(usaAddr, 2);
      await drainTo(rwUSA, admin, USDC(5));
      await escrow.poke(usaAddr);
      expect(await balanceOf(usaAddr)).to.equal(SEED_USA);
    });

    it("resets the next UTC day", async function () {
      const { escrow, rwUSA, admin, usaAddr } = await loadFixture(deployFixture);

      for (let i = 0; i < 3; i++) {
        await drainTo(rwUSA, admin, USDC(5));
        await escrow.poke(usaAddr);
      }
      expect(await escrow.refillsToday(usaAddr)).to.equal(3n);

      await warp(DAY + 1);
      // Pause to drain without auto-refill, then unpause and poke
      await escrow.setOutboundPaused(true);
      await drainTo(rwUSA, admin, USDC(5));
      await escrow.setOutboundPaused(false);
      await escrow.poke(usaAddr);
      // Refill happened (cap adapts based on day-1 usage, so just check it topped up)
      const after = await balanceOf(usaAddr);
      expect(after).to.be.gt(USDC(5));
      const [, , , cap] = await escrow.getRegional(0);
      expect(after).to.equal(cap);
    });
  });

  describe("pauses", function () {
    it("outbound pause blocks refills, unpause resumes", async function () {
      const { escrow, rwUSA, admin, usaAddr } = await loadFixture(deployFixture);
      await escrow.setOutboundPaused(true);

      await drainTo(rwUSA, admin, USDC(5));
      await escrow.poke(usaAddr);
      expect(await balanceOf(usaAddr)).to.equal(USDC(5));

      await escrow.setOutboundPaused(false);
      await escrow.poke(usaAddr);
      expect(await balanceOf(usaAddr)).to.equal(SEED_USA);
    });

    it("only admin can pause", async function () {
      const { escrow, stranger } = await loadFixture(deployFixture);
      await expect(escrow.connect(stranger).setOutboundPaused(true)).to.be.reverted;
      await expect(escrow.connect(stranger).setInboundPaused(true)).to.be.reverted;
    });
  });

  describe("emergency drain", function () {
    it("moves all funds to treasury and pauses both flows", async function () {
      const { escrow, treasury, escrowAddr } = await loadFixture(deployFixture);
      const escrowBal = await balanceOf(escrowAddr);
      const treasuryBefore = await balanceOf(treasury.address);

      await expect(escrow.emergencyDrain(treasury.address)).to.emit(escrow, "EmergencyDrain");

      expect(await balanceOf(escrowAddr)).to.equal(0);
      expect(await balanceOf(treasury.address)).to.equal(treasuryBefore + escrowBal);

      const dials = await escrow.dials();
      expect(dials.outboundPaused).to.equal(true);
      expect(dials.inboundPaused).to.equal(true);
    });

    it("defaults to treasury when destination is zero", async function () {
      const { escrow, treasury, escrowAddr } = await loadFixture(deployFixture);
      const treasuryBefore = await balanceOf(treasury.address);
      const escrowBal = await balanceOf(escrowAddr);

      await escrow.emergencyDrain(ethers.ZeroAddress);
      expect(await balanceOf(treasury.address)).to.equal(treasuryBefore + escrowBal);
    });

    it("only admin can drain", async function () {
      const { escrow, stranger, treasury } = await loadFixture(deployFixture);
      await expect(escrow.connect(stranger).emergencyDrain(treasury.address)).to.be.reverted;
    });
  });

  describe("dials", function () {
    it("all setters work", async function () {
      const { escrow } = await loadFixture(deployFixture);
      await escrow.setTriggerBps(8000);
      await escrow.setMaxPullsPerDay(5);
      await escrow.setSeedPhaseOutDays(14);
      await escrow.setEscrowCap(USDC(50000));
      await escrow.setEscrowRefillThreshold(USDC(10000));

      const d = await escrow.dials();
      expect(d.triggerBps).to.equal(8000);
      expect(d.maxPullsPerDay).to.equal(5);
      expect(d.seedPhaseOutDays).to.equal(14);
      expect(d.escrowCap).to.equal(USDC(50000));
      expect(d.escrowRefillThreshold).to.equal(USDC(10000));
    });

    it("rejects over-cap deposits", async function () {
      const { escrow, admin, escrowAddr } = await loadFixture(deployFixture);
      // Lower the cap to just above current balance, then try to exceed it
      const bal = await ethers.provider.getBalance(escrowAddr);
      await escrow.setEscrowCap(bal + USDC(100));
      await expect(admin.sendTransaction({ to: escrowAddr, value: USDC(200) }))
        .to.be.revertedWithCustomError(escrow, "OverEscrowCap");
    });

    it("only admin can change dials", async function () {
      const { escrow, stranger } = await loadFixture(deployFixture);
      await expect(escrow.connect(stranger).setTriggerBps(8000)).to.be.reverted;
    });
  });

  describe("two-step rotation", function () {
    it("propose + accept rotates a regional wallet", async function () {
      const { escrow, admin, usaAddr } = await loadFixture(deployFixture);
      const signers = await ethers.getSigners();
      const replacement = signers[10];

      await escrow.proposeRegionalWallet(0, replacement.address);
      const [, pending] = await escrow.getRegional(0);
      expect(pending).to.equal(replacement.address);

      await expect(escrow.connect(admin).acceptRegionalRole(0))
        .to.be.revertedWithCustomError(escrow, "NotProposed");

      await escrow.connect(replacement).acceptRegionalRole(0);
      const [w0, pendingAfter] = await escrow.getRegional(0);
      expect(w0).to.equal(replacement.address);
      expect(pendingAfter).to.equal(ethers.ZeroAddress);
      expect(await escrow.isRegistered(replacement.address)).to.equal(true);
      expect(await escrow.isRegistered(usaAddr)).to.equal(false);
    });
  });

  describe("RegionalWallet blind poke", function () {
    it("poke fires on sponsor and refills when needed", async function () {
      const { rwUSA, admin, usaAddr } = await loadFixture(deployFixture);
      // sponsor() drains to 50 (below 10%) — blind poke should auto-refill
      await rwUSA.connect(admin).sponsor(admin.address, SEED_USA - USDC(5));
      expect(await balanceOf(usaAddr)).to.equal(SEED_USA);
    });

    it("sponsor works normally when no refill needed", async function () {
      const { rwUSA, admin, usaAddr } = await loadFixture(deployFixture);
      await rwUSA.connect(admin).sponsor(admin.address, USDC(1));
      expect(await balanceOf(usaAddr)).to.equal(SEED_USA - USDC(1));
    });

    it("sponsor never breaks even if escrow is paused", async function () {
      const { escrow, rwUSA, admin, usaAddr } = await loadFixture(deployFixture);
      await escrow.setOutboundPaused(true);
      // try/catch in sponsor() means this must succeed regardless
      await rwUSA.connect(admin).sponsor(admin.address, USDC(120));
      expect(await balanceOf(usaAddr)).to.equal(SEED_USA - USDC(120));
    });
  });
});
