import { expect } from "chai";
import { ethers } from "hardhat";
import {
  ArcPaymaster__factory,
  MockEntryPoint__factory,
  ERC1967Proxy__factory,
} from "../typechain-types";
import {
  sponsorshipDigest,
  buildPaymasterAndData,
  signSponsorship,
  recoverSponsorshipSigner,
  parsePaymasterGasLimits,
  packAccountGasLimits,
  packGasFees,
  unpackHigh128,
  unpackLow128,
} from "../scripts/sponsor-digest";

/**
 * Proves scripts/sponsor-digest.ts byte-matches ArcPaymaster._sponsorshipDigest
 * through the REAL on-chain verification path (validatePaymasterUserOp).
 *
 * If the helper differed from the contract by even one bit, ECDSA.recover would
 * yield a different address and the call would revert with BadSignature.
 */

const EXECUTE_SELECTOR = "0xb61d27f6";
const OP_REGISTER = 1;

describe("paymaster digest helper byte-match", function () {
  async function deployPaymaster() {
    const [owner, alice] = await ethers.getSigners();
    const verifyingSigner = ethers.Wallet.createRandom().connect(ethers.provider);

    const mockEP = await (await ethers.getContractFactory("MockEntryPoint")).deploy();
    await mockEP.waitForDeployment();

    const impl = await (await ethers.getContractFactory("ArcPaymaster")).deploy();
    await impl.waitForDeployment();
    const initData = (await ethers.getContractFactory("ArcPaymaster")).interface.encodeFunctionData(
      "initialize",
      [owner.address, owner.address, await mockEP.getAddress(), verifyingSigner.address, owner.address, 1000, 100]
    );
    const proxy = await (await ethers.getContractFactory("ERC1967Proxy")).deploy(
      await impl.getAddress(),
      initData
    );
    await proxy.waitForDeployment();

    const paymaster = ArcPaymaster__factory.connect(await proxy.getAddress(), owner);
    const entrypoint = MockEntryPoint__factory.connect(await mockEP.getAddress(), owner);

    // allowlist an arbitrary (target, selector) for OP_REGISTER
    const target = alice.address;
    const selector = "0x12345678";
    await (await paymaster.setTargetAllowed(target, selector, OP_REGISTER)).wait();
    // fund the deposit on the mock entrypoint
    await (await paymaster.deposit({ value: ethers.parseEther("1") })).wait();

    return { owner, alice, verifyingSigner, paymaster, entrypoint, target, selector };
  }

  /** Build a full sponsored userOp using ONLY the shared helper (no inline digest math). */
  async function buildOp(
    ctx: Awaited<ReturnType<typeof deployPaymaster>>,
    opts: { tamperDigestInput?: boolean } = {}
  ) {
    const { alice, verifyingSigner, target, selector } = ctx;
    const paymasterAddr = await ctx.paymaster.getAddress();
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const now = (await ethers.provider.getBlock("latest"))!.timestamp;
    const validUntil = now + 3600;
    const validAfter = now - 10;

    const innerCalldata = selector + "00".repeat(32); // any bytes starting with the selector
    const callData = ethers.concat([
      EXECUTE_SELECTOR,
      ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint256", "bytes"], [target, 0, innerCalldata]),
    ]);

    const vGas = 100000n;
    const pGas = 50000n;
    // The signature is always computed over the TRUE validUntil. When
    // tampering, the op itself carries validUntil+1, so the contract
    // recomputes a different digest -> BadSignature.
    const opValidUntil = opts.tamperDigestInput ? validUntil + 1 : validUntil;
    const params = {
      paymaster: paymasterAddr,
      chainId,
      sender: alice.address,
      nonce: 0n,
      initCode: "0x",
      callData,
      accountGasLimits: packAccountGasLimits(200000n, 500000n),
      preVerificationGas: 100000n,
      gasFees: packGasFees(1000000000n, 2000000000n),
      verificationGasLimit: vGas,
      postOpGasLimit: pGas,
      validUntil,
      validAfter,
      opType: OP_REGISTER,
    };
    const digest = sponsorshipDigest(params);
    const signature = await signSponsorship(verifyingSigner, digest);
    const paymasterAndData = buildPaymasterAndData(
      paymasterAddr, vGas, pGas, opValidUntil, validAfter, OP_REGISTER, signature
    );
    return { params: { ...params, validUntil: opValidUntil }, paymasterAndData, sender: alice.address, digest };
  }

  it("helper digest verifies through the real validatePaymasterUserOp (byte-equal)", async function () {
    const ctx = await deployPaymaster();
    const { entrypoint, paymaster } = ctx;
    const { params, paymasterAndData, sender } = await buildOp(ctx);
    const userOp = [
      sender, 0, "0x", params.callData,
      params.accountGasLimits, params.preVerificationGas, params.gasFees,
      paymasterAndData, "0x",
    ] as any;
    await expect(
      entrypoint.forwardValidate(await paymaster.getAddress(), userOp, ethers.ZeroHash, 1000)
    ).to.not.be.reverted;
  });

  it("a digest input changed after signing is rejected (proves the check is live)", async function () {
    const ctx = await deployPaymaster();
    const { entrypoint, paymaster } = ctx;
    // signed for validUntil, but the op carries validUntil+1 -> contract recomputes
    // a different digest -> BadSignature
    const { params, paymasterAndData, sender } = await buildOp(ctx, { tamperDigestInput: true });
    const userOp = [
      sender, 0, "0x", params.callData,
      params.accountGasLimits, params.preVerificationGas, params.gasFees,
      paymasterAndData, "0x",
    ] as any;
    await expect(
      entrypoint.forwardValidate(await paymaster.getAddress(), userOp, ethers.ZeroHash, 1000)
    ).to.be.revertedWithCustomError(paymaster, "BadSignature");
  });

  it("mutating the signature bytes never moves the digest (no circular signing)", async function () {
    const ctx = await deployPaymaster();
    const { verifyingSigner } = ctx;
    const paymasterAddr = await ctx.paymaster.getAddress();
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const base = {
      paymaster: paymasterAddr, chainId, sender: ctx.alice.address, nonce: 0n,
      initCode: "0x", callData: "0x1234",
      accountGasLimits: packAccountGasLimits(1n, 2n), preVerificationGas: 3n,
      gasFees: packGasFees(4n, 5n),
      verificationGasLimit: 6n, postOpGasLimit: 7n,
      validUntil: 100, validAfter: 90, opType: OP_REGISTER,
    };
    const d1 = sponsorshipDigest(base);
    // changing gas limits DOES move it (they are bound, not ignored)
    const d2 = sponsorshipDigest({ ...base, verificationGasLimit: 999n });
    expect(d2).to.not.equal(d1);
    // and the signature over it recovers the verifying signer
    const sig = await signSponsorship(verifyingSigner, d1);
    expect(recoverSponsorshipSigner(d1, sig)).to.equal(verifyingSigner.address);
    // paymasterAndData round-trips through the contract's own parse offsets
    const pmd = buildPaymasterAndData(paymasterAddr, 6n, 7n, 100, 90, OP_REGISTER, sig);
    expect(pmd.length).to.equal(2 + (52 + 256) * 2); // 0x + 308 bytes
    const parsed = parsePaymasterGasLimits(pmd);
    expect(parsed.verificationGasLimit).to.equal(6n);
    expect(parsed.postOpGasLimit).to.equal(7n);
  });

  it("pack/unpack helpers round-trip", async function () {
    const packed = packAccountGasLimits(123456n, 789012n);
    expect(unpackHigh128(packed)).to.equal(123456n);
    expect(unpackLow128(packed)).to.equal(789012n);
    const fees = packGasFees(11n, 22n);
    expect(unpackHigh128(fees)).to.equal(11n);
    expect(unpackLow128(fees)).to.equal(22n);
  });
});
