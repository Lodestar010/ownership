import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { Interface } from "ethers";
import {
  Registry__factory,
  Registrar__factory,
  Resolver__factory,
  ReverseRegistrar__factory,
  BrandVault__factory,
  Marketplace__factory,
  Splitter__factory,
  ArcPaymaster__factory,
  AttestationRegistry__factory,
  MockEntryPoint__factory,
  ERC1967Proxy__factory,
} from "../typechain-types";

/**
 * End-to-end tests for the .arc naming service on the local Hardhat network.
 * Mirrors the deploy script's wiring but keeps admin = deployer (no timelock
 * handover) so tests can act as the admin.
 */

const DAY = 24 * 3600;
const TERM = 730 * DAY;
const GRACE = 90 * DAY;
const PARK_PERIOD = 365 * DAY;

const EXECUTE_SELECTOR = "0xb61d27f6";
const OP = { REGISTER: 1, RENEW: 2, RECORD: 3, SUBNAME: 4 };

async function warp(seconds: number) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine", []);
}

function nodeForLabel(label: string): string {
  return ethers.keccak256(
    ethers.concat([
      "0x" + "00".repeat(32),
      ethers.keccak256(ethers.toUtf8Bytes(label)),
    ])
  );
}

describe("Naming service", function () {
  async function deployFixture() {
    const [owner, alice, bob, wSponsor, wTreasury, wSecurity] = await ethers.getSigners();
    const verifyingSigner = ethers.Wallet.createRandom().connect(ethers.provider);

    async function deployProxy(factoryName: string, initArgs: any[]) {
      const factory = await ethers.getContractFactory(factoryName);
      const impl = await factory.deploy();
      await impl.waitForDeployment();
      const data = factory.interface.encodeFunctionData("initialize", initArgs);
      const proxyFactory = await ethers.getContractFactory("ERC1967Proxy");
      const proxy = await proxyFactory.deploy(await impl.getAddress(), data);
      await proxy.waitForDeployment();
      return proxy;
    }

    const registryP = await deployProxy("Registry", [owner.address]);
    const splitterP = await deployProxy("Splitter", [
      wSponsor.address, wTreasury.address, wSecurity.address, owner.address, 5000, 3000, 2000,
    ]);
    const registrarP = await deployProxy("Registrar", [
      owner.address, await registryP.getAddress(), await splitterP.getAddress(),
    ]);
    const resolverP = await deployProxy("Resolver", [owner.address, await registryP.getAddress()]);
    const reverseP = await deployProxy("ReverseRegistrar", [
      owner.address, await registryP.getAddress(), await resolverP.getAddress(),
    ]);
    const vaultP = await deployProxy("BrandVault", [
      owner.address, await registryP.getAddress(), await registrarP.getAddress(), await splitterP.getAddress(),
    ]);
    const marketP = await deployProxy("Marketplace", [
      owner.address, await registryP.getAddress(), await registrarP.getAddress(), await splitterP.getAddress(),
    ]);
    const attestP = await deployProxy("AttestationRegistry", [owner.address, owner.address]);

    const mockEP = await (await ethers.getContractFactory("MockEntryPoint")).deploy();
    await mockEP.waitForDeployment();

    const paymasterP = await deployProxy("ArcPaymaster", [
      owner.address, owner.address, await mockEP.getAddress(), verifyingSigner.address,
      owner.address, 1000, 100, // low/critical thresholds (wei, test-scale)
    ]);

    const registry = Registry__factory.connect(await registryP.getAddress(), owner);
    const registrar = Registrar__factory.connect(await registrarP.getAddress(), owner);
    const resolver = Resolver__factory.connect(await resolverP.getAddress(), owner);
    const reverseRegistrar = ReverseRegistrar__factory.connect(await reverseP.getAddress(), owner);
    const vault = BrandVault__factory.connect(await vaultP.getAddress(), owner);
    const marketplace = Marketplace__factory.connect(await marketP.getAddress(), owner);
    const splitter = Splitter__factory.connect(await splitterP.getAddress(), owner);
    const paymaster = ArcPaymaster__factory.connect(await paymasterP.getAddress(), owner);
    const attestations = AttestationRegistry__factory.connect(await attestP.getAddress(), owner);
    const entrypoint = MockEntryPoint__factory.connect(await mockEP.getAddress(), owner);

    // ---- wiring (mirrors scripts/deploy.ts phase 2) ----
    await (await registry.setController(await registrarP.getAddress(), true)).wait();
    await (await registrar.setNotifier(await resolverP.getAddress(), true)).wait();
    await (await resolver.setRegistrar(await registrarP.getAddress())).wait();
    await (await registrar.setMarketplace(await marketP.getAddress())).wait();
    await (await registrar.setBrandVault(await vaultP.getAddress())).wait();
    await (await registrar.setAllowlisted(await vaultP.getAddress(), true)).wait();
    await (await registrar.setAllowlisted(owner.address, true)).wait();
    // attestation registry gates the family free path (spec §17)
    await (await registrar.setAttestationRegistry(await attestP.getAddress())).wait();
    await (await attestations.attest(owner.address, 0)).wait(); // owner: orientation
    const ROOT = "0x" + "00".repeat(32);
    await (await registry.setController(owner.address, true)).wait();
    await (await registry.setSubnodeOwner(ROOT, ethers.keccak256(ethers.toUtf8Bytes("reverse")), await reverseP.getAddress())).wait();
    await (await registry.setController(owner.address, false)).wait();
    await (await reverseRegistrar.setReverseRootResolver()).wait();
    await (await vault.setDefaultResolver(await resolverP.getAddress())).wait();

    // paymaster target allowlist
    const allow = async (target: string, factoryName: string, fn: string, opType: number) => {
      const sel = (await ethers.getContractFactory(factoryName)).interface.getFunction(fn)!.selector;
      await (await paymaster.setTargetAllowed(target, sel, opType)).wait();
    };
    await allow(await registrarP.getAddress(), "Registrar", "register(string,address)", OP.REGISTER);
    await allow(await registrarP.getAddress(), "Registrar", "renew(string)", OP.RENEW);
    await allow(await registrarP.getAddress(), "Registrar", "registerSubname(bytes32,string,address)", OP.SUBNAME);
    await allow(await resolverP.getAddress(), "Resolver", "setAddr(bytes32,address)", OP.RECORD);
    await allow(await resolverP.getAddress(), "Resolver", "setText(bytes32,string,string)", OP.RECORD);
    await allow(await resolverP.getAddress(), "Resolver", "setContenthash(bytes32,bytes)", OP.RECORD);
    await (await paymaster.setSybilAllowlisted(owner.address, true)).wait();

    // fund the paymaster deposit (via the mock entrypoint)
    await (await paymaster.deposit({ value: ethers.parseEther("1") })).wait();

    return {
      owner, alice, bob, verifyingSigner,
      registry, registrar, resolver, reverseRegistrar, vault, marketplace, splitter, paymaster, entrypoint,
      attestations,
      addrs: {
        registry: await registryP.getAddress(), registrar: await registrarP.getAddress(),
        resolver: await resolverP.getAddress(), vault: await vaultP.getAddress(),
        marketplace: await marketP.getAddress(), paymaster: await paymasterP.getAddress(),
      },
    };
  }

  // ---------- Registrar: registration & pricing ----------

  it("registers names: allowlisted free, outsiders pay tier + matching fee", async function () {
    const { owner, alice, registry, registrar, splitter } = await deployFixture();
    await registrar.setTierPrice(3, ethers.parseEther("0.1"));
    await registrar.setMatchingFee(ethers.parseEther("0.01"));

    // owner is allowlisted -> free 7+ char name
    await expect(registrar.register("freebird", owner.address)).to.not.be.reverted;
    expect(await registry.owner(nodeForLabel("freebird"))).to.equal(owner.address);

    // alice (not allowlisted) registers a 3-char name: tier + matching fee -> splitter
    const splitBefore = await ethers.provider.getBalance(await splitter.getAddress());
    await registrar.connect(alice).register("abc", alice.address, {
      value: ethers.parseEther("0.11"),
    });
    const splitAfter = await ethers.provider.getBalance(await splitter.getAddress());
    expect(splitAfter - splitBefore).to.equal(ethers.parseEther("0.11"));

    // 1-2 chars locked
    await expect(
      registrar.connect(alice).register("ab", alice.address, { value: ethers.parseEther("1") })
    ).to.be.revertedWithCustomError(registrar, "NameLocked");
    // duplicate
    await expect(
      registrar.connect(alice).register("abc", alice.address, { value: ethers.parseEther("1") })
    ).to.be.revertedWithCustomError(registrar, "AlreadyRegistered");
    // underpayment
    await expect(
      registrar.connect(alice).register("def", alice.address, { value: ethers.parseEther("0.05") })
    ).to.be.revertedWithCustomError(registrar, "InsufficientPayment");
  });

  it("renews for free; grace period then park escrows ownership", async function () {
    const { owner, alice, registrar, registry } = await deployFixture();
    await registrar.register("lifecycle", alice.address);
    const node = nodeForLabel("lifecycle");
    const e1 = await registrar.expiryOf(node);

    // renew before expiry extends from the old expiry
    await registrar.connect(alice).renew("lifecycle");
    expect(await registrar.expiryOf(node)).to.equal(e1 + BigInt(TERM));

    // warp past the renewed expiry + grace -> park escrows to the registrar, resolver cleared
    await warp(2 * TERM + GRACE + DAY);
    await registrar.park("lifecycle");
    expect(await registry.owner(node)).to.equal(await registrar.getAddress());
    expect(await registrar.isParked(node)).to.equal(true);

    // reclaim restores owner + fresh 1-year term
    await registrar.connect(alice).reclaim("lifecycle");
    expect(await registry.owner(node)).to.equal(alice.address);
    expect(await registrar.isParked(node)).to.equal(false);
  });

  it("releases a name after the park period and it becomes re-registrable", async function () {
    const { owner, alice, bob, registrar, registry } = await deployFixture();
    await registrar.register("recycled", alice.address);
    const node = nodeForLabel("recycled");
    await warp(TERM + GRACE + DAY);
    await registrar.park("recycled");
    // too early
    await expect(registrar.release("recycled")).to.be.revertedWithCustomError(registrar, "ParkNotExpired");
    await warp(PARK_PERIOD + DAY);
    await registrar.release("recycled");
    // bob (allowlisted? no - owner is allowlisted; bob pays 0 for 7+ chars anyway)
    await registrar.connect(bob).register("recycled", bob.address);
    expect(await registry.owner(node)).to.equal(bob.address);
  });

  it("record activity auto-renews the term via the resolver hook", async function () {
    const { owner, alice, registrar, resolver, registry } = await deployFixture();
    await registrar.register("activeuser", alice.address);
    const node = nodeForLabel("activeuser");
    await registry.connect(alice).setResolver(node, await resolver.getAddress());
    const e1 = await registrar.expiryOf(node);
    await warp(100 * DAY);
    await resolver.connect(alice).setText(node, "bio", "hello");
    const e2 = await registrar.expiryOf(node);
    expect(e2).to.be.gt(e1); // pushed to a full term from now
  });

  // ---------- Subnames ----------

  it("subnames: parent-authorized, expiry bound to parent, revocable", async function () {
    const { owner, alice, bob, registrar, registry } = await deployFixture();
    await registrar.register("parentname", alice.address);
    const parent = nodeForLabel("parentname");
    await registrar.connect(alice).registerSubname(parent, "kid", bob.address);
    const sub = ethers.keccak256(ethers.concat([parent, ethers.keccak256(ethers.toUtf8Bytes("kid"))]));
    expect(await registry.owner(sub)).to.equal(bob.address);
    // expiry bound to parent term
    expect(await registrar.expiryOf(sub)).to.be.lte(await registrar.expiryOf(parent));
    // stranger cannot mint under alice's name
    await expect(
      registrar.connect(bob).registerSubname(parent, "evil", bob.address)
    ).to.be.revertedWithCustomError(registrar, "Unauthorized");
    // parent revokes by default: the subname returns to the parent owner's control
    await registrar.connect(alice).revokeSubname(parent, "kid");
    expect(await registry.owner(sub)).to.equal(alice.address);
    // one-way permanence
    await registrar.connect(alice).makeSubnamesPermanent(parent);
    await expect(registrar.connect(alice).makeSubnamesPermanent(parent)).to.not.be.reverted; // idempotent
    await registrar.connect(alice).registerSubname(parent, "kid2", bob.address);
    await expect(registrar.connect(alice).revokeSubname(parent, "kid2")).to.be.revertedWithCustomError(
      registrar, "SubnamePermanent"
    );
  });

  // ---------- Marketplace & fee curve ----------

  it("fee curve: 20% day-0 decaying quadratically to 2% at 2 years", async function () {
    const { owner, marketplace } = await deployFixture();
    // pure math check against the locked spec values (no chain needed beyond view)
    const node = nodeForLabel("curve");
    // We check the formula via a fresh registration's acquiredAt below; here just sanity on constants
    expect(await marketplace.FEE_CAP_BPS()).to.equal(2000);
    expect(await marketplace.FEE_FLOOR_BPS()).to.equal(200);
    expect(await marketplace.FEE_HORIZON_DAYS()).to.equal(730);
    void node;
  });

  it("marketplace sale pays the commons fee and resets term + hold clock", async function () {
    const { owner, alice, bob, registrar, registry, marketplace, splitter } = await deployFixture();
    await registrar.register("forsale", alice.address);
    const node = nodeForLabel("forsale");

    // seller approves marketplace once, then lists
    await registry.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);
    const price = ethers.parseEther("1");
    await marketplace.connect(alice).list("forsale", price);

    // day-0 sale: 20% fee
    expect(await marketplace.feeBpsFor(node)).to.equal(2000);
    const splitBefore = await ethers.provider.getBalance(await splitter.getAddress());
    await marketplace.connect(bob).buy("forsale", { value: price });
    const splitAfter = await ethers.provider.getBalance(await splitter.getAddress());
    expect(splitAfter - splitBefore).to.equal(ethers.parseEther("0.2")); // 20% of 1
    expect(await registry.owner(node)).to.equal(bob.address);
    // hold clock restarted
    expect(await marketplace.feeBpsFor(node)).to.equal(2000);

    // warp ~1 year: fee decays to ~6.5%
    await warp(365 * DAY);
    const bps = await marketplace.feeBpsFor(node);
    expect(bps).to.be.closeTo(650, 5);

    // warp to 2 years: floor 2%
    await warp(365 * DAY);
    expect(await marketplace.feeBpsFor(node)).to.equal(200);
  });

  it("marketplace enumerates active listings on-chain (spec §16)", async function () {
    const { alice, bob, registrar, registry, marketplace } = await deployFixture();
    await registrar.register("enumone", alice.address);
    await registrar.register("enumtwo", alice.address);
    const n1 = nodeForLabel("enumone");
    const n2 = nodeForLabel("enumtwo");
    await registry.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);

    await marketplace.connect(alice).list("enumone", ethers.parseEther("1"));
    await marketplace.connect(alice).list("enumtwo", ethers.parseEther("2"));
    // re-listing the same name updates price without duplicating the entry
    await marketplace.connect(alice).list("enumone", ethers.parseEther("1.5"));

    expect(await marketplace.activeListingCount()).to.equal(2);
    expect(await marketplace.isListed(n1)).to.equal(true);
    expect(await marketplace.isListed(n2)).to.equal(true);
    const page = await marketplace.getActiveListings(0, 10);
    expect(page.length).to.equal(2);
    expect(page).to.include(n1);
    expect(page).to.include(n2);
    // pagination slices
    expect((await marketplace.getActiveListings(0, 1)).length).to.equal(1);
    expect((await marketplace.getActiveListings(5, 10)).length).to.equal(0);

    // cancel removes from enumeration (swap-and-pop keeps it consistent)
    await marketplace.connect(alice).cancelListing("enumone");
    expect(await marketplace.activeListingCount()).to.equal(1);
    expect(await marketplace.isListed(n1)).to.equal(false);
    expect(await marketplace.activeListingAt(0)).to.equal(n2);

    // buying also removes from enumeration
    await marketplace.connect(bob).buy("enumtwo", { value: ethers.parseEther("2") });
    expect(await marketplace.activeListingCount()).to.equal(0);
    expect(await marketplace.isListed(n2)).to.equal(false);
  });

  it("attestation gate (spec §17): orientation attestation unlocks the family free path", async function () {
    const { alice, bob, registrar, attestations } = await deployFixture();
    await registrar.setTierPrice(3, ethers.parseEther("0.1"));
    await registrar.setMatchingFee(ethers.parseEther("0.01"));

    // alice allowlisted but NOT attested -> pays as an outsider
    await registrar.setAllowlisted(alice.address, true);
    expect(await registrar.isFamilyFree(alice.address)).to.equal(false);
    const [t, f] = await registrar.quoteFor("abc", alice.address);
    expect(t).to.equal(ethers.parseEther("0.1"));
    expect(f).to.equal(ethers.parseEther("0.01"));
    await expect(
      registrar.connect(alice).register("abc", alice.address, { value: ethers.parseEther("0.11") })
    ).to.not.be.reverted;

    // attested -> free
    await attestations.attest(alice.address, 0);
    expect(await registrar.isFamilyFree(alice.address)).to.equal(true);
    const [t2, f2] = await registrar.quoteFor("abcdefg", alice.address);
    expect(t2).to.equal(0);
    expect(f2).to.equal(0);
    await expect(registrar.connect(alice).register("abcdefg", alice.address)).to.not.be.reverted;

    // revoke -> free path closes again
    await attestations.revoke(alice.address, 0);
    expect(await registrar.isFamilyFree(alice.address)).to.equal(false);

    // non-issuer cannot mint; bad track reverts
    await expect(attestations.connect(bob).attest(bob.address, 0)).to.be.reverted;
    await expect(attestations.attest(bob.address, 9)).to.be.reverted;
    // idempotent: double-attest is a no-op, not a revert
    await attestations.attest(alice.address, 1);
    await expect(attestations.attest(alice.address, 1)).to.not.be.reverted;
    expect(await attestations.hasTrack(alice.address, 1)).to.equal(true);
  });

  it("P2P transfers pay no fee and do not reset the term", async function () {
    const { owner, alice, bob, registrar, registry } = await deployFixture();
    await registrar.register("p2pname", alice.address);
    const node = nodeForLabel("p2pname");
    const acq1 = await registrar.acquiredAtOf(node);
    const exp1 = await registrar.expiryOf(node);
    await warp(30 * DAY);
    await registry.connect(alice).setOwner(node, bob.address); // direct P2P, no marketplace
    expect(await registrar.acquiredAtOf(node)).to.equal(acq1);
    expect(await registrar.expiryOf(node)).to.equal(exp1);
  });

  // ---------- BrandVault ----------

  it("brand vault: seed, ROFR claim, and auction lifecycle", async function () {
    const { owner, alice, bob, vault, registry, registrar, splitter } = await deployFixture();
    await vault.reserveLabels(["acme"]);
    const node = nodeForLabel("acme");
    expect(await vault.isReserved(node)).to.equal(true);
    expect(await registry.owner(node)).to.equal(await vault.getAddress());

    // non-allowlisted claim reverts
    await expect(vault.connect(alice).claimReserved("acme")).to.be.revertedWithCustomError(vault, "NotAllowlistedClaimer");
    // verify alice as the mark holder, then claim at tier price (7+ free -> 0; use 4-char for price)
    await vault.reserveLabels(["nike"]);
    const nike = nodeForLabel("nike");
    await registrar.setTierPrice(4, ethers.parseEther("0.05"));
    await vault.setClaimAllowlist("nike", alice.address);
    const splitBefore = await ethers.provider.getBalance(await splitter.getAddress());
    await vault.connect(alice).claimReserved("nike", { value: ethers.parseEther("0.05") });
    expect(await registry.owner(nike)).to.equal(alice.address);
    expect(await vault.isReserved(nike)).to.equal(false);
    const splitAfter = await ethers.provider.getBalance(await splitter.getAddress());
    expect(splitAfter - splitBefore).to.equal(ethers.parseEther("0.05"));

    // auction: start -> bid -> outbid -> settle; proceeds to splitter
    await vault.startAuction("acme");
    await vault.connect(alice).bid("acme", { value: ethers.parseEther("0.3") });
    await vault.connect(bob).bid("acme", { value: ethers.parseEther("0.4") }); // >= 105% of 0.3
    // too-low bid reverts
    await expect(vault.connect(alice).bid("acme", { value: ethers.parseEther("0.41") })).to.be.revertedWithCustomError(
      vault, "BidTooLow"
    );
    // alice withdraws outbid funds
    const balBefore = await ethers.provider.getBalance(alice.address);
    const tx = await vault.connect(alice).withdraw("acme");
    const receipt = await tx.wait();
    const gas = receipt!.gasUsed * receipt!.gasPrice;
    expect(await ethers.provider.getBalance(alice.address)).to.be.closeTo(
      balBefore + ethers.parseEther("0.3") - gas, 1000n
    );
    await warp(3 * DAY + 60);
    const sBefore = await ethers.provider.getBalance(await splitter.getAddress());
    await vault.settleAuction("acme");
    expect(await registry.owner(node)).to.equal(bob.address);
    const sAfter = await ethers.provider.getBalance(await splitter.getAddress());
    expect(sAfter - sBefore).to.equal(ethers.parseEther("0.4"));
  });

  it("brand vault: auction rate limit enforced on-chain", async function () {
    const { vault } = await deployFixture();
    const labels = Array.from({ length: 11 }, (_, i) => `brand${i}`);
    await vault.reserveLabels(labels);
    for (let i = 0; i < 10; i++) {
      await vault.startAuction(labels[i]);
    }
    await expect(vault.startAuction(labels[10])).to.be.revertedWithCustomError(vault, "RateLimitExceeded");
  });

  it("brand vault: org mark attestation writes the verified text record", async function () {
    const { vault, resolver } = await deployFixture();
    await vault.reserveLabels(["initech"]);
    await vault.attestOrg("initech", "Initech LLC | EIN 12-3456789 | verified 2026-10-01");
    const node = nodeForLabel("initech");
    expect(await resolver.text(node, "org.verified")).to.equal(
      "Initech LLC | EIN 12-3456789 | verified 2026-10-01"
    );
  });

  // ---------- ReverseRegistrar ----------

  it("reverse registrar: setName records the primary name; claim hands over the node", async function () {
    const { alice, reverseRegistrar, resolver, registry } = await deployFixture();
    await reverseRegistrar.connect(alice).setName("alice.arc");
    const node = await reverseRegistrar.nodeForAddress(alice.address);
    expect(await resolver.text(node, "name")).to.equal("alice.arc");
    expect(await registry.owner(node)).to.equal(await reverseRegistrar.getAddress());
    // clearing
    await reverseRegistrar.connect(alice).setName("");
    expect(await resolver.text(node, "name")).to.equal("");
    // escape hatch
    await reverseRegistrar.connect(alice).claim();
    expect(await registry.owner(node)).to.equal(alice.address);
  });

  // ---------- Splitter ----------

  it("splitter divides income by basis points", async function () {
    const { owner, alice, splitter } = await deployFixture();
    await owner.sendTransaction({ to: await splitter.getAddress(), value: ethers.parseEther("1") });
    const [s, t, f] = await splitter.wallets();
    const b0 = await ethers.provider.getBalance(s);
    await splitter.distribute();
    expect(await ethers.provider.getBalance(s)).to.equal(b0 + ethers.parseEther("0.5"));
    expect(await ethers.provider.getBalance(t)).to.be.gt(0);
    expect(await ethers.provider.getBalance(f)).to.be.gt(0);
    void alice;
  });

  // ---------- Paymaster ----------

  /** Canonical v0.7 sponsorship digest — must match Paymaster._sponsorshipDigest exactly. */
  async function canonicalDigest(
    ctx: Awaited<ReturnType<typeof deployFixture>>,
    op: { sender: string; nonce: number; initCode: string; callData: string; accountGasLimits: string; preVerificationGas: number; gasFees: string },
    vGas: bigint,
    pGas: bigint,
    validUntil: number,
    validAfter: number,
    opType: number
  ) {
    const { addrs } = ctx;
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const opPart = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "bytes32", "bytes32", "bytes32", "uint256", "bytes32"],
        [
          op.sender,
          op.nonce,
          ethers.keccak256(op.initCode),
          ethers.keccak256(op.callData),
          op.accountGasLimits,
          op.preVerificationGas,
          op.gasFees,
        ]
      )
    );
    return ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "uint128", "uint128", "uint256", "address", "uint48", "uint48", "uint8"],
        [opPart, vGas, pGas, chainId, addrs.paymaster, validUntil, validAfter, opType]
      )
    );
  }

  /** Extract vGas/pGas from paymasterAndData exactly like the contract does (bytes 20:36, 36:52). */
  async function digestFromParts(
    ctx: Awaited<ReturnType<typeof deployFixture>>,
    op: { sender: string; nonce: number; initCode: string; callData: string; accountGasLimits: string; preVerificationGas: number; gasFees: string },
    paymasterAndData: Uint8Array,
    validUntil: number,
    validAfter: number,
    opType: number
  ) {
    const vGas = BigInt("0x" + Buffer.from(paymasterAndData.slice(20, 36)).toString("hex"));
    const pGas = BigInt("0x" + Buffer.from(paymasterAndData.slice(36, 52)).toString("hex"));
    return canonicalDigest(ctx, op, vGas, pGas, validUntil, validAfter, opType);
  }

  /** Build a sponsored userOp for `innerCalldata` on `target`, signed by the verifying signer. */
  async function buildSponsoredOp(
    ctx: Awaited<ReturnType<typeof deployFixture>>,
    sender: HardhatEthersSigner,
    target: string,
    innerCalldata: string,
    opType: number,
    overrides: { validUntil?: number; validAfter?: number; signer?: { signMessage(m: Uint8Array): Promise<string> } } = {}
  ) {
    const { verifyingSigner, addrs } = ctx;
    const now = (await ethers.provider.getBlock("latest"))!.timestamp;
    const validUntil = overrides.validUntil ?? now + 3600;
    const validAfter = overrides.validAfter ?? now - 10;
    const signer = overrides.signer ?? verifyingSigner;
    const vGas = 100000n;
    const pGas = 50000n;

    const callData = ethers.concat([
      EXECUTE_SELECTOR,
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "bytes"],
        [target, 0, innerCalldata]
      ),
    ]);
    const opFields = {
      sender: sender.address,
      nonce: 0,
      initCode: "0x",
      callData,
      accountGasLimits: ethers.ZeroHash,
      preVerificationGas: 0,
      gasFees: ethers.ZeroHash,
    };
    // Canonical digest (excludes paymasterAndData and the account signature — never circular).
    const digest = await canonicalDigest(ctx, opFields, vGas, pGas, validUntil, validAfter, opType);
    const signature = await signer.signMessage(ethers.getBytes(digest));

    const paymasterData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint48", "uint48", "uint8", "bytes"],
      [validUntil, validAfter, opType, signature]
    );
    const paymasterAndData = ethers.solidityPacked(
      ["address", "uint128", "uint128", "bytes"],
      [addrs.paymaster, vGas, pGas, paymasterData]
    );
    const userOp = [sender.address, 0, "0x", callData, ethers.ZeroHash, 0, ethers.ZeroHash, paymasterAndData, "0x"] as any;
    return {
      userOp,
      userOpHash: ethers.ZeroHash, // ignored by the paymaster; kept for the EntryPoint call shape
      digest,
      paymasterAndData,
      opFields,
      vGas,
      pGas,
      validUntil,
      validAfter,
    };
  }

  it("paymaster sponsors an allowlisted registration; rejects bad sigs, wrong targets, caps", async function () {
    const ctx = await deployFixture();
    const { alice, bob, registrar, paymaster, entrypoint, verifyingSigner, addrs } = ctx;

    const inner = (registrar.interface as Interface).encodeFunctionData("register(string,address)", ["sponsored", alice.address]);
    const { userOp, userOpHash } = await buildSponsoredOp(ctx, alice, addrs.registrar, inner, OP.REGISTER);
    // happy path through the mock entrypoint
    await expect(entrypoint.forwardValidate(addrs.paymaster, userOp, userOpHash, 1000)).to.not.be.reverted;
    expect(await paymaster.remainingQuota(alice.address, OP.REGISTER)).to.equal(4); // 5 - 1

    // bad signature
    const evil = ethers.Wallet.createRandom().connect(ethers.provider);
    const bad = await buildSponsoredOp(ctx, alice, addrs.registrar, inner, OP.REGISTER, { signer: evil });
    await expect(
      entrypoint.forwardValidate(addrs.paymaster, bad.userOp, bad.userOpHash, 1000)
    ).to.be.revertedWithCustomError(paymaster, "BadSignature");

    // wrong opType for the target (register is OP_REGISTER, not OP_RECORD)
    const wrongType = await buildSponsoredOp(ctx, alice, addrs.registrar, inner, OP.RECORD);
    await expect(
      entrypoint.forwardValidate(addrs.paymaster, wrongType.userOp, wrongType.userOpHash, 1000)
    ).to.be.revertedWithCustomError(paymaster, "TargetNotAllowlisted");

    // non-allowlisted target
    const evilInner = (paymaster.interface as Interface).encodeFunctionData("pause", []);
    const evilOp = await buildSponsoredOp(ctx, alice, addrs.paymaster, evilInner, OP.REGISTER);
    await expect(
      entrypoint.forwardValidate(addrs.paymaster, evilOp.userOp, evilOp.userOpHash, 1000)
    ).to.be.revertedWithCustomError(paymaster, "TargetNotAllowlisted");

    // expired
    const now = (await ethers.provider.getBlock("latest"))!.timestamp;
    const expired = await buildSponsoredOp(ctx, alice, addrs.registrar, inner, OP.REGISTER, {
      validUntil: now - 5,
    });
    await expect(
      entrypoint.forwardValidate(addrs.paymaster, expired.userOp, expired.userOpHash, 1000)
    ).to.be.revertedWithCustomError(paymaster, "Expired");

    // daily cap: 4 more OK (total 5), 6th reverts
    for (let i = 0; i < 4; i++) {
      const o = await buildSponsoredOp(ctx, alice, addrs.registrar, inner, OP.REGISTER);
      await entrypoint.forwardValidate(addrs.paymaster, o.userOp, o.userOpHash, 1000);
    }
    const over = await buildSponsoredOp(ctx, alice, addrs.registrar, inner, OP.REGISTER);
    await expect(
      entrypoint.forwardValidate(addrs.paymaster, over.userOp, over.userOpHash, 1000)
    ).to.be.revertedWithCustomError(paymaster, "DailyCapExceeded");
    void verifyingSigner;
    void bob;
  });

  it("paymaster fails closed when paused or deposit-critical", async function () {
    const ctx = await deployFixture();
    const { owner, alice, registrar, paymaster, entrypoint, addrs } = ctx;
    const inner = (registrar.interface as Interface).encodeFunctionData("register(string,address)", ["sponsored2", alice.address]);

    await paymaster.connect(owner).pause();
    const p = await buildSponsoredOp(ctx, alice, addrs.registrar, inner, OP.REGISTER);
    await expect(entrypoint.forwardValidate(addrs.paymaster, p.userOp, p.userOpHash, 1000)).to.be.revertedWithCustomError(
      paymaster, "Paused_"
    );
    await paymaster.connect(owner).unpause();

    // drain the deposit below critical via withdrawToVault, then validation must fail
    await paymaster.connect(owner).withdrawToVault(ethers.parseEther("1"));
    const p2 = await buildSponsoredOp(ctx, alice, addrs.registrar, inner, OP.REGISTER);
    await expect(
      entrypoint.forwardValidate(addrs.paymaster, p2.userOp, p2.userOpHash, 1000)
    ).to.be.revertedWithCustomError(paymaster, "DepositCritical");
  });

  it("paymaster digest excludes paymasterAndData and the signature (B1: no circular signing)", async function () {
    const ctx = await deployFixture();
    const { alice, registrar, entrypoint, addrs } = ctx;
    const inner = (registrar.interface as Interface).encodeFunctionData("register(string,address)", ["nocircle", alice.address]);
    const built = await buildSponsoredOp(ctx, alice, addrs.registrar, inner, OP.REGISTER);

    // Mutate ONLY the signature bytes inside paymasterAndData (keep vGas/pGas/times/opType):
    // the digest extracted exactly like the contract does must not move.
    const original = ethers.getBytes(built.paymasterAndData);
    const mutatedSig = ethers.getBytes(built.paymasterAndData);
    mutatedSig[mutatedSig.length - 1] ^= 0xff; // flip a bit deep in the signature region
    const d1 = await digestFromParts(ctx, built.opFields, original, built.validUntil, built.validAfter, OP.REGISTER);
    const d2 = await digestFromParts(ctx, built.opFields, mutatedSig, built.validUntil, built.validAfter, OP.REGISTER);
    expect(d2).to.equal(d1);
    expect(d1).to.equal(built.digest);

    // Sanity: mutating the gas-limit region DOES move the digest (it is bound, not ignored).
    const mutatedGas = ethers.getBytes(built.paymasterAndData);
    mutatedGas[20] ^= 0xff;
    const d3 = await digestFromParts(ctx, built.opFields, mutatedGas, built.validUntil, built.validAfter, OP.REGISTER);
    expect(d3).to.not.equal(d1);

    // And the happy path proves the CONTRACT recomputes this exact digest (signature verifies).
    await expect(entrypoint.forwardValidate(addrs.paymaster, built.userOp, built.userOpHash, 1000)).to.not.be.reverted;
  });

  it("paymaster stakes with the entrypoint (B2: guardian-gated, ERC-7562)", async function () {
    const ctx = await deployFixture();
    const { owner, alice, paymaster, entrypoint, addrs } = ctx;
    await paymaster.connect(owner).stake(86400, { value: ethers.parseEther("0.5") });
    expect(await entrypoint.stakeOf(addrs.paymaster)).to.equal(ethers.parseEther("0.5"));
    // non-guardian cannot stake
    await expect(paymaster.connect(alice).stake(86400, { value: 1 })).to.be.reverted;
    // unlock + withdraw round-trips to the chosen address
    await paymaster.connect(owner).unlockStake();
    const balBefore = await ethers.provider.getBalance(alice.address);
    await paymaster.connect(owner).withdrawStake(alice.address);
    expect(await entrypoint.stakeOf(addrs.paymaster)).to.equal(0);
    expect(await ethers.provider.getBalance(alice.address)).to.equal(balBefore + ethers.parseEther("0.5"));
  });

  it("reverse names resolve through the standard registry -> resolver path (B3)", async function () {
    const { alice, reverseRegistrar, resolver, registry } = await deployFixture();
    await reverseRegistrar.connect(alice).setName("alice.arc");
    const node = await reverseRegistrar.nodeForAddress(alice.address);
    // the standard resolution path works: registry -> resolver -> text record
    const resolverAddr = await registry.resolver(node);
    expect(resolverAddr).to.equal(await resolver.getAddress());
    const viaRegistry = await ethers.getContractAt("Resolver", resolverAddr);
    expect(await viaRegistry.text(node, "name")).to.equal("alice.arc");
    // after claim, the resolver pointer survives the handover
    await reverseRegistrar.connect(alice).claim();
    expect(await registry.owner(node)).to.equal(alice.address);
    expect(await registry.resolver(node)).to.equal(await resolver.getAddress());
  });

  it("vault-held brand names are exempt from park/release (B4)", async function () {
    const { owner, vault, registrar } = await deployFixture();
    await vault.reserveLabels(["brandexempt"]);
    await registrar.register("ordinaryname", owner.address); // control: a normal name
    // warp past expiry + grace for both
    await warp(TERM + GRACE + DAY);
    await expect(registrar.park("brandexempt")).to.be.revertedWithCustomError(registrar, "ParkExempt");
    // the exemption is selective: ordinary names still park
    await expect(registrar.park("ordinaryname")).to.not.be.reverted;
    expect(await registrar.isParked(nodeForLabel("ordinaryname"))).to.equal(true);
  });

  it("vault claim/auction winners get a fresh 2-year term and a restarted hold clock (B5)", async function () {
    const { alice, bob, vault, registrar, marketplace } = await deployFixture();
    await vault.reserveLabels(["wxyz", "qwer"]);
    await registrar.setTierPrice(4, ethers.parseEther("0.05"));
    // let the seed term decay so a stale inherited term would be visible
    await warp(365 * DAY);

    const before = (await ethers.provider.getBlock("latest"))!.timestamp;
    await vault.setClaimAllowlist("wxyz", alice.address);
    await vault.connect(alice).claimReserved("wxyz", { value: ethers.parseEther("0.05") });
    const nodeW = nodeForLabel("wxyz");
    expect(await registrar.expiryOf(nodeW)).to.be.closeTo(BigInt(before + TERM), 30n);
    expect(await registrar.acquiredAtOf(nodeW)).to.be.closeTo(BigInt(before), 30n);
    // hold clock restarted: marketplace fee is back at the 20% day-0 cap
    expect(await marketplace.feeBpsFor(nodeW)).to.equal(2000);

    // auction path
    await vault.startAuction("qwer");
    await vault.connect(bob).bid("qwer", { value: ethers.parseEther("0.2") });
    await warp(3 * DAY + 60);
    const before2 = (await ethers.provider.getBlock("latest"))!.timestamp;
    await vault.settleAuction("qwer");
    const nodeQ = nodeForLabel("qwer");
    expect(await registrar.expiryOf(nodeQ)).to.be.closeTo(BigInt(before2 + TERM), 30n);
    expect(await registrar.acquiredAtOf(nodeQ)).to.be.closeTo(BigInt(before2), 30n);
    expect(await marketplace.feeBpsFor(nodeQ)).to.equal(2000);
  });

  it("brand vault: claims and auctions are mutually exclusive (S3)", async function () {
    const { alice, bob, vault } = await deployFixture();
    await vault.reserveLabels(["mutex"]);
    // auction first, then a claim allowlist entry lands: the claim is blocked while the auction is live
    await vault.startAuction("mutex");
    await vault.setClaimAllowlist("mutex", alice.address);
    await expect(vault.connect(alice).claimReserved("mutex")).to.be.revertedWithCustomError(
      vault, "AuctionAlreadyLive"
    );
    // after cancellation the claim goes through
    await vault.cancelAuction("mutex");
    await vault.connect(alice).claimReserved("mutex");
    expect(await vault.isReserved(nodeForLabel("mutex"))).to.equal(false);

    // reverse order: a claim-allowlisted name cannot be auctioned
    await vault.reserveLabels(["mutex2"]);
    await vault.setClaimAllowlist("mutex2", bob.address);
    await expect(vault.startAuction("mutex2")).to.be.revertedWithCustomError(vault, "ClaimPending");
  });

  it("a revoked subname can be re-registered (S4)", async function () {
    const { alice, bob, registrar, registry } = await deployFixture();
    await registrar.register("resubparent", alice.address);
    const parent = nodeForLabel("resubparent");
    await registrar.connect(alice).registerSubname(parent, "kid", bob.address);
    const sub = ethers.keccak256(ethers.concat([parent, ethers.keccak256(ethers.toUtf8Bytes("kid"))]));
    await registrar.connect(alice).revokeSubname(parent, "kid");
    expect(await registry.owner(sub)).to.equal(alice.address);
    // re-register the same subname — must not revert AlreadyRegistered
    await registrar.connect(alice).registerSubname(parent, "kid", bob.address);
    expect(await registry.owner(sub)).to.equal(bob.address);
  });

  it("a stale listing can be cancelled by the new owner after a P2P transfer (S5)", async function () {
    const { alice, bob, registrar, registry, marketplace } = await deployFixture();
    await registrar.register("stalelisting", alice.address);
    await registry.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);
    await marketplace.connect(alice).list("stalelisting", ethers.parseEther("1"));
    const node = nodeForLabel("stalelisting");
    expect(await marketplace.isListed(node)).to.equal(true);
    // alice P2P-transfers the name to bob; the listing is now stale
    await registry.connect(alice).setOwner(node, bob.address);
    // bob (not the seller, not an operator) can cancel the dead listing
    await marketplace.connect(bob).cancelListing("stalelisting");
    expect(await marketplace.isListed(node)).to.equal(false);
    expect(await marketplace.activeListingCount()).to.equal(0);
  });

  it("quoteFor reverts for unregistrable 1-2 char labels (S10)", async function () {
    const { alice, registrar } = await deployFixture();
    await expect(registrar.quoteFor("ab", alice.address)).to.be.revertedWithCustomError(registrar, "NameLocked");
    // sane quotes still work
    const [t, f] = await registrar.quoteFor("abcdefg", alice.address);
    expect(t).to.equal(0);
    expect(f).to.equal(0);
  });
});
