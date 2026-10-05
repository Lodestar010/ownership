import { ethers } from "ethers";

/**
 * Canonical ERC-4337 v0.7 sponsorship-digest helpers for the ArcPaymaster.
 *
 * These MUST byte-match ArcPaymaster._sponsorshipDigest exactly:
 *
 *   opPart = keccak256(abi.encode(
 *     sender, nonce,
 *     keccak256(initCode), keccak256(callData),
 *     accountGasLimits, preVerificationGas,
 *     gasFees                          // NOTE: raw bytes32, NOT hashed
 *   ))
 *   digest = keccak256(abi.encode(
 *     opPart,
 *     verificationGasLimit,            // uint128 from paymasterAndData[20:36]
 *     postOpGasLimit,                  // uint128 from paymasterAndData[36:52]
 *     block.chainid,
 *     address(this),                   // the paymaster contract
 *     validUntil, validAfter, opType
 *   ))
 *   signed = keccak256("\x19Ethereum Signed Message:\n32" ++ digest)  // EIP-191
 *
 * The digest commits to everything EXCEPT paymasterAndData (which carries the
 * signature) and the account signature — so signing is never circular: compute
 * the digest, sign it, then embed the signature. Changing the signature bytes
 * never changes the digest.
 *
 * Proven byte-equal to the on-chain computation in test/paymaster-digest.test.ts.
 */

export interface SponsorshipDigestParams {
  /** Paymaster contract address (address(this) in the contract). */
  paymaster: string;
  chainId: bigint;
  sender: string;
  nonce: bigint;
  initCode: string; // hex
  callData: string; // hex
  accountGasLimits: string; // bytes32 hex
  preVerificationGas: bigint;
  gasFees: string; // bytes32 hex
  /** Paymaster verification gas limit (paymasterAndData bytes 20:36). */
  verificationGasLimit: bigint;
  /** Paymaster post-op gas limit (paymasterAndData bytes 36:52). */
  postOpGasLimit: bigint;
  validUntil: number; // uint48
  validAfter: number; // uint48
  opType: number; // uint8
}

const coder = ethers.AbiCoder.defaultAbiCoder();

/** The canonical digest — byte-identical to ArcPaymaster._sponsorshipDigest. */
export function sponsorshipDigest(p: SponsorshipDigestParams): string {
  const opPart = ethers.keccak256(
    coder.encode(
      ["address", "uint256", "bytes32", "bytes32", "bytes32", "uint256", "bytes32"],
      [
        p.sender,
        p.nonce,
        ethers.keccak256(p.initCode),
        ethers.keccak256(p.callData),
        p.accountGasLimits,
        p.preVerificationGas,
        p.gasFees,
      ]
    )
  );
  return ethers.keccak256(
    coder.encode(
      ["bytes32", "uint128", "uint128", "uint256", "address", "uint48", "uint48", "uint8"],
      [
        opPart,
        p.verificationGasLimit,
        p.postOpGasLimit,
        p.chainId,
        p.paymaster,
        p.validUntil,
        p.validAfter,
        p.opType,
      ]
    )
  );
}

/** EIP-191 personal_sign wrapping, matching the contract's inline prefix. */
export function ethSignedDigest(digest: string): string {
  return ethers.keccak256(
    ethers.concat([ethers.toUtf8Bytes("\x19Ethereum Signed Message:\n32"), ethers.getBytes(digest)])
  );
}

/** Sign the canonical digest with the verifying signer (EOA). */
export async function signSponsorship(
  signer: { signMessage(m: Uint8Array): Promise<string> },
  digest: string
): Promise<string> {
  return signer.signMessage(ethers.getBytes(digest));
}

/** Recover the signer address from (digest, signature) — mirrors the contract check. */
export function recoverSponsorshipSigner(digest: string, signature: string): string {
  return ethers.recoverAddress(ethSignedDigest(digest), signature);
}

/**
 * paymasterAndData layout (v0.7):
 *   paymaster (20) | verificationGasLimit (16) | postOpGasLimit (16) |
 *   abi.encode(uint48 validUntil, uint48 validAfter, uint8 opType, bytes signature)
 */
export function buildPaymasterAndData(
  paymaster: string,
  verificationGasLimit: bigint,
  postOpGasLimit: bigint,
  validUntil: number,
  validAfter: number,
  opType: number,
  signature: string
): string {
  const paymasterData = coder.encode(
    ["uint48", "uint48", "uint8", "bytes"],
    [validUntil, validAfter, opType, signature]
  );
  return ethers.solidityPacked(
    ["address", "uint128", "uint128", "bytes"],
    [paymaster, verificationGasLimit, postOpGasLimit, paymasterData]
  );
}

/** Extract the paymaster gas limits exactly like the contract does (bytes 20:36, 36:52). */
export function parsePaymasterGasLimits(paymasterAndData: string): {
  verificationGasLimit: bigint;
  postOpGasLimit: bigint;
} {
  const b = ethers.getBytes(paymasterAndData);
  if (b.length < 52) throw new Error("paymasterAndData too short");
  return {
    verificationGasLimit: BigInt("0x" + Buffer.from(b.slice(20, 36)).toString("hex")),
    postOpGasLimit: BigInt("0x" + Buffer.from(b.slice(36, 52)).toString("hex")),
  };
}

/** v0.7 accountGasLimits packing: verificationGasLimit (high 128) | callGasLimit (low 128). */
export function packAccountGasLimits(verificationGasLimit: bigint, callGasLimit: bigint): string {
  return ethers.toBeHex((verificationGasLimit << 128n) | callGasLimit, 32);
}

/** v0.7 gasFees packing: maxPriorityFeePerGas (high 128) | maxFeePerGas (low 128). */
export function packGasFees(maxPriorityFeePerGas: bigint, maxFeePerGas: bigint): string {
  return ethers.toBeHex((maxPriorityFeePerGas << 128n) | maxFeePerGas, 32);
}

/** Unpack the high 128 bits of a packed bytes32 field. */
export function unpackHigh128(packed: string): bigint {
  return BigInt(packed) >> 128n;
}

/** Unpack the low 128 bits of a packed bytes32 field. */
export function unpackLow128(packed: string): bigint {
  return BigInt(packed) & ((1n << 128n) - 1n);
}
