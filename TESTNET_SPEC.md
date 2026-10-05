# .arc Naming Service — Testnet Build Spec

**Status:** Draft for build (2026-10-01). Source of truth for the smart-contracts chat.
**Target:** Arc Testnet (chain ID 5042002). No audit required for testnet.
**Solidity:** compile with `evmVersion: "paris"` or earlier (Arc rejects PUSH0).

All decisions below are locked unless marked DEFERRED. Pricing marked PLACEHOLDER — real values set later.

---

## 1. Contract set

| # | Contract | Pattern | Purpose |
|---|----------|---------|---------|
| 1 | Registry | UUPS | namehash → owner / resolver / TTL |
| 2 | Registrar | UUPS | registration, tiers, renewals, grace, re-release, allowlist |
| 3 | Resolver | UUPS | addr / text / contenthash / multichain records |
| 4 | ReverseRegistrar | UUPS | reverse names, forward-verified |
| 5 | Paymaster | ERC-4337 verifying | sponsored gas with caps and degradation |
| 6 | Splitter | UUPS | divides income → sponsor pool / family treasury / security fund |
| 7 | Marketplace | UUPS | resale listings, hold-scaled fee, clock reset |
| 8 | BrandVault | UUPS | reserved names, ROFR claims, scheduled auctions |

Upgrade key for all: admin (Douglas → family multisig). All upgrades behind 7-day timelock.

---

## 2. Registry

- ENS-style separation: registry holds ownership; resolver holds records.
- `owner(namehash)`, `resolver(namehash)`, `ttl(namehash)`; `setSubnodeOwner`, `setResolver`, `setOwner`, `setTTL`.
- Root node (`0x0…0` for `.arc`) owned by admin; two-step propose/accept transfer with 7-day delay. Never silent.

## 3. Registrar

**Pricing (PLACEHOLDER values on testnet):**
- 7+ chars: FREE. 3/4/5/6 chars: tiered one-time price (bands locked, amounts later).
- 1–2 chars: locked, not registrable (until Phase 3+ special allocation).
- Family/verified allowlist: fee-exempt (office manages list; members hold keys).

**Terms & renewal:**
- 2-year terms. Renewal FREE forever.
- Activity auto-renews: any owner-initiated use (record update, transfer, subname creation) resets the term.
- Annual ping is off-chain (wallet computes expiry locally, one-click sponsored renew).
- 90-day grace: only previous owner can renew.
- After grace: name parks — resolution stops, owner can reclaim (one click) for 1 extra year.
- After park: ordinary names return to public pool; premium (<7) names return via premium path (tier price).
- Brand-vault names (Merkle proof of reservation) cannot register here — see §8.

**Anti-squat:** tier pricing + hold-scaled resale fee (see §7). No Harberger, no transfer restrictions.

## 4. Resolver

- Standard interfaces: `addr(bytes32)`, `addr(bytes32,uint256)` (multichain), `text(bytes32,string)`, `contenthash(bytes32)`, plus ABI/contenthash where applicable.
- UTS-46 normalization enforced at registration (homograph defense). Follow ENSIP text-record key conventions.

## 5. ReverseRegistrar

- `setName` / `claim`; resolvers MUST forward-verify (resolve the claimed name back to the caller) before displaying.

## 6. Paymaster (ERC-4337 verifying)

- Sponsors: registrations, renewals, record updates, parent-authorized subname creation. NOT premium-auction bids.
- Caps per account per day: 5 registrations / 50 record updates / 20 subnames / 50 renewals. Tunable.
- Two tiers: public caps; family/verified allowlist higher caps. No identity proof at launch.
- Degradation: healthy → normal; low balance → auto-tighten; near-empty → free tier pauses. User-paid txs always work.
- Controls: tighten instant; loosen via 7-day timelock; pause/unpause instant; signer rotation admin-only; sponsor withdrawals ONLY to vault address + timelock.
- Stakes with the EntryPoint (ERC-7562) so bundlers accept its validation-phase quota accounting.
- Trust boundary: can sponsor, cannot take names, touch user funds, or block user-paid txs.

## 7. Marketplace

- Optional listing contract: seller sets price → buyer pays → atomic transfer.
- Commons fee on each sale, scaled by seller hold duration: fast flip ≈ 20%, 2+ year hold ≈ 2%. Exact curve PLACEHOLDER.
- Fee → Splitter. P2P transfers unrestricted (no royalty enforcement off-venue).
- Every resale resets the name's term to a full 2 years and re-enrolls buyer in the renewal cycle. Vault claim/auction wins do the same.

## 8. BrandVault

- Merkle root of reserved names (testnet: small sample list; mainnet: Fortune 1000 + famous marks + Arc ecosystem incl. `circle.arc`).
- Vault-held reservations do not expire: the Registrar exempts vault-owned names from park/release (enforced on-chain).
- ROFR: mark holder claims at tier price. Verification manual at first (corporate domain / USPTO record → allowlisted address).
- Unclaimed names: public English auctions in scheduled batches; rate enforced on-chain (e.g. max N new auctions / month — PLACEHOLDER).
- Claims and auctions are mutually exclusive per name (a live auction blocks its claim; a pending claim blocks its auction).
- Claim and auction winners get a fresh 2-year term and a restarted hold-clock, same as marketplace sales.
- Proceeds → Splitter.
- Competing claimants (Delta rule): first verified wins the bare name; runner-up offered descriptive variant + same package.
- Brand packages (product, mostly off-chain at first): name + on-chain verified-org mark + subname fleet + revocability choice + API + support. Annual price → family treasury. PLACEHOLDER.

## 9. Splitter

- Receives: tier sales, marketplace fees, auction proceeds, outsider matching fees, B2B/package revenue, sponsor placements.
- Divides by percentage to three purpose-wallets: **sponsor pool**, **family treasury**, **security fund**. Ratios PLACEHOLDER.
- Percentage changes: admin, timelocked.
- Wallet addresses are deploy-time parameters. Ownership (Douglas / trust / entity) DEFERRED to trust-law review.

## 10. Subnames

- Parent owner authorizes creation (paymaster sponsors 20/day).
- Subname expiry ≤ parent expiry (bound to parent).
- Revocability: parent-level setting, default revocable; flippable to permanent.
- Parent-set pricing, free default.

## 11. Key-compromise playbook (no new code)

No global kill-switch. On suspected compromise: (1) pause paymaster (instant — stops sponsor drain), (2) tighten registrar caps (instant), (3) rotate paymaster signer + admin keys, (4) timelocked recovery actions, (5) unpause. The 7-day timelocks on root transfer, loosening, withdrawals, and upgrades are the detection windows — a thief cannot move silently.

## 12. Phases

- **Phase 0 (now):** testnet. Demo app, no real names, placeholder pricing, sample vault list.
- **Phase 1:** family alpha, mainnet, allowlist, free. Requires audit first.
- **Phase 2:** verified users/partners.
- **Phase 3:** public, paymaster live with caps. 1–2 chars unlock via special allocation.

**Gate:** no mainnet deployment holding the real root before audit (contest sweep → fix → traditional audit → bounty).

## 13. Explicitly deferred (not testnet blockers)

- Exact tier prices, split ratios, fee curves, auction rate, package prices — set later (first-pass sheet: `pricing/arc-tier-pricing-first-pass.xlsx`).
- Trademark dispute process beyond the vault (needed before public phase).
- IPFS pinning strategy (needed before frontend/DID launch).
- Gas measurement — do it on testnet, replace the $0.01 illustration.
- Wallet/root ownership (trust-law review).
- Succession re-walk (tracked separately).

## 14. Anti-impersonation stack

Goal: curb misspelled/imposter scam names (e.g. `nkie.arc`). A "must be a real word" rule was considered and rejected — dictionaries are incomplete and centralized; it would block brands, tags, and new slang.
- Brand vault reserves exact brand strings (see §8). Typosquats are NOT reserved (infinite game).
- UTS-46 confusable detection blocks visual spoofs at registration (see §3).
- Verified-org mark (see §8): wallets display verified names distinctly; imposters cannot fake the mark.
- Wallet similarity warnings (Site 1 wallet requirement): warn when the user enters a name within small edit distance of a verified name.
- Dispute process for bad-faith typosquatting: deferred to pre-public phase.

## 15. Deploy checklist (testnet)
- [ ] Deploy registry, registrar, resolver, reverse registrar, paymaster, splitter, marketplace, brand vault
- [ ] Wire deploy-time params: admin, splitter wallets (test addresses), paymaster signer, vault address, placeholder tiers, sample Merkle root
- [ ] Register test names incl. subnames; exercise renewal, grace, park, resale, auction
- [ ] Measure real gas per operation; record in §13 follow-up
- [ ] Demo app resolves names via standard interfaces

## 16. Indexing (no trusted servers)

Query layer is layered; the protocol never depends on any indexer.

1. **Owner-scoped queries** ("my names", "my listings"): plain RPC `eth_getLogs`
   with filters on contract events. Zero infrastructure.
2. **Global queries** (search, browse): permissionless IPFS snapshots. An
   open-source publisher script (we run the first instance; anyone can run one)
   reads chain events, builds the full dataset hourly, and publishes a
   content-addressed snapshot with a Merkle tree over entries. Clients use
   snapshots as *hints* for search/browse and MUST confirm against the chain
   (`eth_call` or Merkle proof) before anything affecting funds or ownership.
   No canonical publisher, no API keys. Lying publishers are caught by
   recomputation; clients can switch publishers freely.
3. **Marketplace**: keep on-chain enumeration of active listings (small dataset,
   readable without any indexer).
4. Third-party indexers (The Graph-style) are allowed as a convenience for devs,
   never required by the protocol.

**Contract requirement:** all state-changing events MUST carry indexed parameters
for the fields indexers filter on (namehash, owner, etc.). Marketplace MUST
expose on-chain enumeration of active listings.

## 17. Education attestations (soulbound, on-chain)

Education tracks (orientation; role tracks for successor trustee, office
management, name holder) complete with a non-transferable on-chain attestation.
There is no token: the `AttestationRegistry` (UUPS, 9th contract) keeps a
per-account bitmap of completed tracks. `ISSUER_ROLE` (whoever runs the
education program — the builder on testnet, the family office on mainnet)
mints and revokes; both are idempotent. Admin is the 7-day timelock.

Tracks: 0 = orientation, 1 = successor, 2 = management, 3 = name holder.
New tracks may be appended; existing ids are stable.

**Gating (locked):** the Registrar's family-allowlist free path requires the
allowlist AND a live orientation attestation (`isFamilyFree`). Allowlisted
accounts without the attestation pay as outsiders — the gate withholds the
benefit, never the registration itself. Successor/management designations
gate on their tracks when those contracts are built. Rule: gate the
designation, never the emergency claim.

**Contract requirement:** `Attested`/`Revoked` events carry indexed
`account` and `track` (§16). The Registrar MUST consult the registry on the
free path and fail closed (unwired registry = nobody free).
