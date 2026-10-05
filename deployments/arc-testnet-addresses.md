# Arc Testnet Deployment — Verified Addresses

Deployed 2026-10-02 ~00:06 CDT by `0x9b5D6e41a3c0E4eb10c685Acd44CB29Db14451ab` (69 txs, all successful).
Independently verified on-chain 2026-10-02 via rpc.testnet.arc.network + explorer.testnet.arc.io.
Chain: Arc testnet, chain ID 5042002. Canonical EntryPoint v0.7: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`.

| Contract | Proxy | Implementation |
|---|---|---|
| TimelockController (7-day) | `0xb2d277c1E4479467CF5ed74D3Dad762753a55B10` | — (not a proxy) |
| Registry | `0x523553fC7fC78F97386F0740847d9E594119D8Bb` | `0xa840f7fcea85336201fa03fd457103fa5f7d4bd4` |
| Splitter | `0x97C777fAFb537424865F8FFD10394aA95aFf1EA7` | `0x21bf9465aaf3db5c41c1ec1edcc6c2468981da05` |
| Registrar | `0xb8351Bcc980dA96b091C42092b8d53A7C647E35b` | `0x395fd3ff73602377ddf593e400b305f46b991d34` |
| Resolver | `0x60B2120627d543958C8427d8a61B26223EDb0D53` | `0x906e63bf67a46cd3605da534b1683d2090d5865e` |
| ReverseRegistrar | `0x32c531834149Aa0b392Bbe7aBBeFF01e0250c28f` | `0xb5ed2c606c079bc0002e0013cb857b7d44d48751` |
| BrandVault | `0xF8fc7789B3Ba88015ED22d25301Bed6F1f164403` | `0xc25139f18a610d00c7a0494f6fd0d20615275062` |
| Marketplace | `0xE6E6C61B714da1D65FEa492626868c446021b063` | `0x71e2e47f4f63a3f531e1fcc21a0f2a99191438b2` |
| AttestationRegistry | `0x7057FDa7d054B36CF2BAa0aa7292a8Cebf2edBde` | `0x8e728082c46929e1ed702bdd4b3090d16681a93a` |
| ArcPaymaster | `0xcd629172f31d9a25279Ac5fAB333312dC63De67c` | `0xda0fad85ceb99ebf9e3ce96a71b74392c6c91d91` |

## Verified state
- All 9 proxies live (standard OZ ERC1967Proxy bytecode); implementation slots match creation receipts.
- `DEFAULT_ADMIN_ROLE` == timelock on all 9; deployer renounced everywhere; timelock self-administered.
- Wiring: Registry→Registrar controller; Registrar→Marketplace/AttestationRegistry/BrandVault; Resolver→Registrar; ReverseRegistrar→Resolver; BrandVault defaultResolver + Merkle root set; seeded `acme` owned by BrandVault; reverse-root resolver set; deployer `isFamilyFree` == true (allowlisted + orientation attested).
- Paymaster: deposit = 1.0 USDC, stake = 1.0 USDC, staked = true (ERC-7562 compliant).
- Splitter: 5000/3000/2000 bps (placeholder ratios).

## Live proof (completed 2026-10-02 ~17:56 CDT)
- Paymaster sponsorship proven against the real Pimlico bundler: ERC-4337 v0.7 user op sponsored by ArcPaymaster; name `pimlico-proof-d46a.arc` registered; deposit 2.0 → 1.96937 USDC; userOpHash `0xe5a80f5997b6c4c5bcf64656019262b01e3e69697964acd5a03c308118f9ade3`, mined success=true.
