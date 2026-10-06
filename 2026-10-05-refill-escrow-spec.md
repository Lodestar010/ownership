# Refill Escrow Spec — v0.1 (DRAFT for DJ review)

**Date:** 2026-10-05
**Status:** Draft — not implemented, not audited
**Purpose:** Programmed reserve wallet (sponsorship wallet #4) that holds funds and releases them to the three regional sponsor wallets on demand. The refill wallet IS the escrow — no separate contract.

All numeric values below are **TEMPORARY testnet placeholders**, flagged as such in code. Real allocations are deferred until post-grant + post-audit.

---

## 1. Role in the system

The refill escrow sits between the Splitter/treasury and the three regional sponsor wallets (USA, Europe, Asia/Africa). It holds reserve funds and tops up regionals as they spend on gas sponsorship. It never touches user transactions directly — it only transacts with the three registered regional wallets.

```
Treasury/Splitter → Refill Escrow → Regional Wallets (USA/EU/ASIA) → Paymaster → users
```

## 2. Registered regional wallets

Three addresses, set at deployment, changeable only via timelock:

| Region      | Testnet daily cap (seed) |
|-------------|--------------------------|
| USA         | 1,250 USDC               |
| Europe      | 2,500 USDC               |
| Asia/Africa | 5,000 USDC               |

Only these three addresses may receive refills. Any other address passed to `poke()` reverts.

## 3. Release logic — `poke(regionalWallet)`

`poke()` is permissionless — anyone may call it for any registered regional. The escrow performs all checks and math on-chain. A release executes **iff ALL** of the following hold:

1. **Target is registered** — the address passed to `poke()` is one of the three regional wallet addresses.
2. **Balance trigger** — the regional's current balance ≤ 10% of its daily cap (i.e., 90% of cap spent).
3. **Daily pull limit** — the regional has received fewer than `maxPullsPerDay` (testnet: 3) refills in the current UTC day.
4. **Sufficient escrow balance** — escrow holds at least the refill amount.

**Release amount:** `dailyCap - regionalBalance` (top up to 100% of the regional's daily cap, never more).

**If escrow cannot cover the full top-up:** send the entire remaining escrow balance and emit `EscrowDepleted` event. A depleted escrow is a funding signal — the escrow pulls from the Splitter (see §12).

**Poke model (DECIDED 2026-10-05):** the escrow performs all balance checks, MA calculations, and refill decisions on-chain. Regional wallets are fully passive: they hold and spend, nothing more. **Refinement (decided 2026-10-05):** each regional wallet includes a single logic-free `escrow.poke(address(this))` call in its sponsorship transaction flow. No balance checks, no conditions — just a blind trigger. This gives near-atomic poke timing (fires with every spend) while keeping regionals logic-free. The escrow still performs all decisions. This keeps customer-facing contracts minimal and concentrates all logic in one auditable contract.

## 4. Circuit breaker

If `poke()` is called for a regional that has already received `maxPullsPerDay` refills today:

- No funds move (the release conditions fail silently — no revert, so the blind poke in the regional's flow never breaks sponsorship).
- The escrow emits `CircuitBreakerTripped(regionalWallet, dayRefillCount)`.
- No further auto-refills for that wallet until the next UTC day **or** manual intervention.

Manual intervention paths (timelock-gated):
- `approveExtraPulls(wallet, count)` — authorize additional pulls for the day (for legitimate demand spikes after human review).
- `pauseWallet(wallet)` / `unpauseWallet(wallet)` — halt/resume a regional wallet entirely (for suspected attack).

The circuit-breaker event is the trigger for the off-chain alert (Gotify → DJ's phone).

## 5. Daily caps — adaptive moving average

Each regional wallet has a daily cap that adapts to real usage.

**Cold start (seed phase):**
- Day 1: cap = seed value (no history yet).
- Days 2–21: cap = (recorded daily usage + seed filling unrecorded days) ÷ 21. The seed's weight shrinks each day; fully phased out by day 21.

**Steady state (day 22+):**
- Cap = 21-day moving average of daily usage.
- Same-weekday weighting applies once ≥3 samples per weekday exist (e.g., Mondays averaged against prior Mondays).

**MA window progression (testnet experiments):**
- The window lengths used during cold start are settable: default progression 3 → 5 → 7 → 10 → 21 days.
- Testnet will trial multiple progressions; data picks the mainnet configuration.

**Usage recording:** each regional wallet reports its daily spend to the escrow (or the escrow reads it). The escrow stores per-wallet, per-day usage for the trailing 21 days minimum.

**Cap recalculation:** lazy/on-demand (decided 2026-10-05). Caps are recomputed automatically whenever `requestRefill()` or `poke()` is called — no keeper, no scheduled trigger. The escrow reads the stored usage history and applies the current MA window progression.

## 6. Emergency controls (escrow itself)

Timelock-gated functions for escrow-level emergencies (added 2026-10-05):

- `pauseOutbound()` / `unpauseOutbound()` — halts all refills to regionals. Regional wallets keep their existing balances and keep operating; they just can't draw more until unpaused.
- `pauseInbound()` / `unpauseInbound()` — halts the escrow's pulls from the Splitter. Used if the Splitter is suspected compromised; the escrow keeps refilling regionals from its existing balance. (Decided 2026-10-05.)
- `emergencyDrain(destination)` — moves all escrow funds to a timelock-specified address. For use only if the escrow logic itself is found to be compromised. Destination defaults to the Treasury wallet.
- All emit events. All require timelock (7-day on mainnet, direct on testnet).

## 7. All parameters are dials, not constants

Every tunable value is a storage variable with a timelock-gated setter. **Nothing** in sections 2–5 is hardcoded. Full dial list:

| Dial | Testnet value | Setter |
|------|---------------|--------|
| Regional wallet addresses (3) | TBD at deploy | `setRegionalWallet(region, addr)` |
| Daily cap seeds (3) | 1250 / 2500 / 5000 | `setSeedCap(region, amount)` |
| MA window progression | [3,5,7,10,21] | `setMAWindows(uint8[])` |
| Seed phase-out days | 21 | `setSeedPhaseOutDays(uint8)` |
| Balance trigger threshold | 90% | `setTriggerBps(9000)` |
| Max pulls per day | 3 | `setMaxPullsPerDay(uint8)` |
| Escrow cap | 25,000 USDC | `setEscrowCap(uint256)` |

On testnet, the builder (DJ) calls setters directly for fast iteration. On mainnet, all setters route through the 7-day timelock.

## 8. Escrow cap and overflow

- Escrow cap (testnet): 25,000 USDC.
- The escrow **rejects** deposits that would exceed its cap (revert on overfill).
- **Overflow rule:** any funds that would exceed a wallet's cap/ceiling route to the Treasury wallet (wallet #8), not the escrow.

## 9. Funding priority (testnet)

When revenue is insufficient to fill all wallets, fund in this order (decided 2026-10-05, review before mainnet):

1. Sponsor system (wallets 1–4)
2. Team (9) + Operations (6)
3. Security (5)
4. Marketing (7)
5. Treasury (8) — fills via overflow regardless

## 10. Contract pattern

- **UUPS upgradeable** proxy, following project standard.
- **AccessControl**: `DEFAULT_ADMIN_ROLE` = 7-day TimelockController.
- **Arc-compatible**: compile with `evmVersion: "paris"` (no PUSH0).
- **No external dependencies**: no oracles, no keepers, no off-chain computation. All logic on-chain.
- **Reentrancy**: pull-based release with checks-effects-interactions; use OZ `ReentrancyGuard` (storage-based, per project Arc quirks doc).

## 11. Test plan (to be executed on testnet)

- **Scenario tests**: steady traffic, gradual growth, sudden spike, sustained surge (circuit breaker trip), griefing attack (bounded loss), regional imbalance, escrow depletion, cold start day 1→21.
- **Parameter sweeps**: MA progressions (3-5-7-10-21 vs 5-10-15-21 vs others), trigger thresholds (80/90/95%), pull limits (2/3/5 per day).
- **Unit + fuzz**: release conditions in isolation, random inputs against `poke()`.

## 12. Escrow funding flow (decided 2026-10-05)

The escrow pulls from the Splitter using the same poke pattern as regionals pull from the escrow (option 3; second choice was automatic Splitter forwarding). When the escrow balance drops below a settable threshold (`escrowRefillThreshold`, testnet TBD), it pulls from the Splitter up to its cap — provided the Splitter holds funds and the funding priority order permits. The Splitter exposes a `fundEscrow()` function callable only by the registered escrow address. Funding priority logic lives at the Splitter level: sponsor system (wallets 1–4) is first in line. On testnet, DJ funds the escrow directly by setting balances.

## 13. Open items

- Adaptive (volatility-responsive) window selection: v2 candidate for mainnet if testnet data warrants. Not in v0.1.
- Mainnet cap/ceiling values: deferred until post-grant + post-audit.

## 14. Security considerations (added 2026-10-05, full pass)

- **Gas-efficient poke:** `poke()` does the cheap check first (read regional balance, compare to 10% of cap) and exits early if no refill is needed. The expensive MA recalculation only runs when a refill is actually triggered. This keeps the per-transaction overhead of the blind poke minimal.
- **Once-per-day recalculation:** caps are recomputed at most once per UTC day per regional, even if `poke()` is called hundreds of times. Prevents redundant computation and any timing games.
- **Poke griefing:** `poke()` is permissionless, but spamming it only burns the caller's gas — the escrow takes no action unless all release conditions hold. No state changes, no fund movement, no MA distortion from failed pokes.
- **Two-step address changes:** `setRegionalWallet()` uses propose/accept — the timelock proposes a new address, and the new address must call `acceptRegionalRole()` to activate. Prevents fat-finger lockouts and proves the new address is operational. Changing an address resets that regional's daily refill counter.
- **Zero-address guards:** all address setters revert on `address(0)`.
- **Splitter pull bounded:** the escrow's pull from the Splitter can never exceed the escrow's cap, and `fundEscrow()` on the Splitter side is only callable by the registered escrow address. A compromised escrow cannot drain the Splitter beyond its own cap.
- **Event emissions (transparency):** every state-changing action emits an event — `RefillExecuted`, `CircuitBreakerTripped`, `EscrowDepleted`, `CapRecalculated`, `DialChanged`, `RegionalWalletProposed/Accepted`, `OutboundPaused/Unpaused`, `InboundPaused/Unpaused`, `EmergencyDrain`. Off-chain monitoring subscribes to all of these.
- **UTC day boundary:** defined as `block.timestamp / 86400`. Daily refill counters reset on day rollover, evaluated lazily on next `poke()`.
- **Upgrade safety:** UUPS `_authorizeUpgrade` gated on timelock. Storage layout must be preserved across upgrades (append-only).

---

*Spec v0.1 — awaiting DJ review. Not implemented. All numbers temporary.*
