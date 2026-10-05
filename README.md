# Ownership — Arc Naming Service

**Yours outright and freely.**

Ownership is an ENS-style naming service native to Arc, offering `.arc` names through 9 UUPS-upgradeable smart contracts governed by a 7-day timelock.

## What it is

- **9 UUPS-upgradeable contracts** — registry, registrar, resolver, reverse registrar, marketplace, brand vault, fee splitter, attestation registry, and an ERC-4337 paymaster — all behind a **7-day timelock**.
- **Free names, sponsored gas** — names of 7+ characters are free with no renewal rent; short names are tiered. A verifying ERC-4337 paymaster sponsors gas in USDC.
- **On-chain brand protection** — a Merkle-reserved vault guards trademarked names.
- **did:arc** — a W3C-compatible decentralized identity method anchored to Arc, defined in [DID_ARC_METHOD_SPEC.md](DID_ARC_METHOD_SPEC.md).

## Status

**Testnet only — contracts unaudited. Audit gates mainnet.**

Live on Arc testnet (chain ID `5042002`). Verified deployment addresses: [deployments/arc-testnet-addresses.md](deployments/arc-testnet-addresses.md). Full testnet spec: [TESTNET_SPEC.md](TESTNET_SPEC.md).

## For developers

Contract ABIs and TypeScript types are published on npm as [`@lodestarfo/arc-naming-contracts`](https://www.npmjs.com/package/@lodestarfo/arc-naming-contracts) (source in [`packages/arc-naming-contracts`](packages/arc-naming-contracts)).

```bash
npm install
npx hardhat compile
npx hardhat test
```

> Note: Arc rejects the `PUSH0` opcode — contracts are compiled with `evmVersion: "paris"` (see `hardhat.config.ts`).

## Brand

Brand identity, colors, and logo usage live in [brand/IDENTITY.md](brand/IDENTITY.md); social-ready artwork in [brand/social](brand/social).

## License

AGPLv3 — see [LICENSE](LICENSE). Commercial dual-licensing available on request.
