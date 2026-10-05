# did:arc DID Method Specification

**Status:** Draft v0.1 (2026-10-01) — for review, not yet submitted for registration.
**Authors:** Lodestar / .arc naming service project.
**Target system:** Arc chain (testnet chain ID 5042002; mainnet TBD).

This document specifies the `arc` DID method per W3C DID Core. It is designed to work
with the .arc naming service: names for humans, DIDs for machines, one root of trust.

---

## 1. Method name

The method name is `arc`:

```
did:arc:<method-specific-identifier>
```

## 2. Method-specific identifier

The method-specific identifier is the EVM address that controls the DID,
lowercase hexadecimal with `0x` prefix:

```
arc-method-specific-id = "0x" 40*HEXDIG
```

Example: `did:arc:0x9b5d6e41a3c0e4eb10c685acd44cb29db14451ab`

Rationale: address-derived DIDs need no on-chain registration to exist. The DID is
usable the moment the keypair exists — matching the self-sovereignty requirement.
(This mirrors the approach of `did:ethr`.)

ABNF (full):

```
did-arc = "did:arc:" 40*HEXDIG   ; lowercase hex, 0x prefix included in practice
```

## 3. CRUD operations

### 3.1 Create

Generate a secp256k1 keypair. The DID is `did:arc:<address>`. No blockchain
transaction is required — the base DID document is implicit (see 3.2).

Linking a `.arc` name is a separate, optional step: the name owner sets a `did`
text record on the name's resolver pointing at the DID, and/or sets the reverse
record for the address to the name.

### 3.2 Read (Resolve)

Resolution is deterministic and needs no trusted server. Given `did:arc:<address>`:

1. **Base document** — constructed implicitly:
   ```json
   {
     "@context": ["https://www.w3.org/ns/did/v1"],
     "id": "did:arc:0x9b5d…51ab",
     "verificationMethod": [{
       "id": "did:arc:0x9b5d…51ab#controller",
       "type": "EcdsaSecp256k1RecoveryMethod2020",
       "controller": "did:arc:0x9b5d…51ab",
       "blockchainAccountId": "eip155:5042002:0x9b5d…51ab"
     }],
     "authentication": ["did:arc:0x9b5d…51ab#controller"],
     "assertionMethod": ["did:arc:0x9b5d…51ab#controller"]
   }
   ```
   The `blockchainAccountId` uses the CAIP-10 `eip155:<chainId>:<address>` format so
   the same DID document works across Arc testnet and mainnet by chain ID.

2. **Name linkage (opt-in)** — query the ReverseRegistrar for `<address>`. If a
   `.arc` name is set and forward-verified (the name resolves back to the address),
   add:
   ```json
   "alsoKnownAs": ["https://arc.names/douglas.arc"]
   ```
   Linkage is opt-in: it only appears if the address owner set the reverse record.

3. **Extended document fields** — query the linked name's resolver for text records
   under the `did:*` namespace:
   - `did:service:<id>` — JSON service endpoint entries, appended to `service`.
   - `did:key:<id>` — additional verification methods (delegates), appended to
     `verificationMethod` with owner-specified purposes.
   - `did:deactivated` — if `"true"`, the DID document MUST be returned with
     `"deactivated": true`.

No new contract is required for v1: document extensions ride on the existing
resolver text-record flow (which the paymaster sponsors).

### 3.3 Update

- **Base layer:** the DID is bound to its key. Key rotation means a new DID.
  This is intentional — the base identifier is stable and self-certifying.
- **Document layer:** the name owner updates `did:*` text records via the normal
  record-update flow (add/remove delegates, service endpoints, link/unlink names).
  Updates are owner-authorized and, for linked names, gas-sponsored.
- A dedicated on-chain DID registry (delegates, rotation without identifier
  change) is reserved for a future version and is NOT part of v0.1.

### 3.4 Deactivate

- **Name-linked DIDs:** the name owner sets the `did:deactivated` text record to
  `"true"`. Resolvers MUST surface `"deactivated": true`.
- **Bare DIDs (no linked name):** v0.1 has no on-chain deactivation. The honest
  statement: lose the key and the DID is simply unusable — which, for a bare
  self-certifying identifier, is equivalent. On-chain deactivation arrives with
  the future DID registry.

## 4. Security considerations

- **Key compromise:** the base DID is only as safe as its key. Document-layer
  fields are owner-controlled via the naming contracts, which inherit the
  project's key-compromise playbook (pause → rotate → timelocked recovery).
- **No central authority** can create, resolve, or revoke a bare `did:arc` DID.
  Resolution is a pure function of chain state plus local computation.
- **Contract upgrade risk:** the resolver/reverse-registrar contracts are UUPS
  upgradeable behind 7-day timelocks (see TESTNET_SPEC). A malicious upgrade
  could alter extended document fields — the timelock is the detection window.
- **alsoKnownAs spoofing:** resolvers MUST forward-verify reverse records before
  surfacing them (already required by the naming spec).

## 5. Privacy considerations

- Bare DIDs are pseudonymous but correlatable: all uses of one DID link to one
  address. Users wanting unlinkability should use pairwise DIDs (one per
  relationship) — supported by the method, no extra machinery.
- Name linkage is **opt-in and public**. Setting a reverse record or a `did`
  text record publicly ties the address to a human-readable name. The wallet
  MUST warn before the user publishes this linkage.
- All `did:*` text records are public chain data. Never put PII in a DID
  document — put a service endpoint that negotiates private exchange instead.

## 6. Registration checklist (not yet done)

- [ ] Submit method to the W3C DID Method Registry.
- [ ] Publish a DIF Universal Resolver driver (anyone can run it; we publish the code).
- [ ] Test vectors: 3 worked resolution examples (bare DID, linked DID, deactivated DID).
- [ ] SDK support in the shared TypeScript core.

## 7. References

- W3C Decentralized Identifiers (DID) v1.0
- `did:ethr` method spec (design precedent for address-derived DIDs)
- CAIP-10 (blockchain account IDs)
- ../TESTNET_SPEC.md (contracts this method resolves through)
