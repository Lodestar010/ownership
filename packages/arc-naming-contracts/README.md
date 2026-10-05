# @lodestarfo/arc-naming-contracts

Everything you need to talk to the **.arc naming service** on Arc — without copying the contracts into your project.

This package gives you:
- **ABIs** for all 9 contracts (so your app can call them)
- **TypeScript types** (so your editor autocompletes and catches mistakes)
- **Deployed addresses** on Arc testnet (so you don't have to look them up)

It does **not** deploy anything. The contracts are already live. You just connect to them.

## Install

```bash
npm install @lodestarfo/arc-naming-contracts
```

You also need `ethers` (version 6) in your project — it's a peer dependency, so install it if you don't have it:

```bash
npm install ethers
```

## Quick concepts

- **Names** look like `alice.arc`. On-chain, every name is a `node` — a hash computed with the same `namehash` algorithm ENS uses. (If you know ENS, you already know how this works.)
- **Registry** = the phone book. It maps each name to its owner and its resolver.
- **Resolver** = the details page. It maps a name to a wallet address, website, avatar, etc.
- **Registrar** = the front desk. It's how new names get registered.
- Always use the **proxy** addresses from this package. (The "implementation" addresses are the code behind the proxy — you never call those directly.)

Not sure which contracts you need? Read the **[integration matrix](../../INTEGRATION_MATRIX.md)** — it tells you exactly which pieces each kind of app needs.

## Example 1: Look up who owns a name

```typescript
import { ethers } from "ethers";
import { proxies, abis } from "@lodestarfo/arc-naming-contracts";

// namehash("alice.arc") — same algorithm as ENS
function namehash(name: string): string {
  let node = "0x" + "00".repeat(32);
  for (const label of name.split(".").reverse()) {
    node = ethers.keccak256(ethers.concat([node, ethers.keccak256(ethers.toUtf8Bytes(label))]));
  }
  return node;
}

const provider = new ethers.JsonRpcProvider("https://rpc.testnet.arc.network");
const registry = new ethers.Contract(proxies.Registry, abis.Registry, provider);

const owner = await registry.owner(namehash("alice.arc"));
console.log("alice.arc is owned by:", owner);
```

## Example 2: Find the wallet address a name points to

```typescript
import { ethers } from "ethers";
import { proxies, abis } from "@lodestarfo/arc-naming-contracts";

const provider = new ethers.JsonRpcProvider("https://rpc.testnet.arc.network");
const registry = new ethers.Contract(proxies.Registry, abis.Registry, provider);
const resolverAddr = await registry.resolver(namehash("alice.arc"));

const resolver = new ethers.Contract(resolverAddr, abis.Resolver, provider);
const wallet = await resolver["addr(bytes32)"](namehash("alice.arc"));
console.log("alice.arc points to:", wallet);
```

## Example 3: Register a new name

Registering goes through the **Registrar**. On testnet, names of 7+ characters are free except for a small matching fee that goes to the family treasury — the exact amount is read live from the contract, so your code never hardcodes it.

```typescript
import { ethers } from "ethers";
import { proxies, abis } from "@lodestarfo/arc-naming-contracts";

const provider = new ethers.JsonRpcProvider("https://rpc.testnet.arc.network");
const signer = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

const registrar = new ethers.Contract(proxies.Registrar, abis.Registrar, signer);
const fee: bigint = await registrar.matchingFee();

const tx = await registrar.register("myname", signer.address, { value: fee });
await tx.wait();
console.log("myname.arc is yours!");
```

## Example 4: Check the paymaster (gas sponsorship)

The **paymaster** can pay gas for your users' transactions, so they don't need testnet funds. Before relying on it, check it has deposit left:

```typescript
import { ethers } from "ethers";
import { proxies, abis } from "@lodestarfo/arc-naming-contracts";

const provider = new ethers.JsonRpcProvider("https://rpc.testnet.arc.network");
const paymaster = new ethers.Contract(proxies.ArcPaymaster, abis.ArcPaymaster, provider);

const deposit = await paymaster.depositBalance();
console.log("Paymaster deposit:", ethers.formatEther(deposit), "USDC");
```

Sponsoring a real transaction uses the ERC-4337 flow (build a user operation, get the paymaster's signature, submit via a bundler like Pimlico). That's more involved — see the [integration matrix](../../INTEGRATION_MATRIX.md) "gasless transactions" row, and the reference script `scripts/test-paymaster-bundler.ts` in the main repo.

## What's in the box

| Folder / file | What it is |
|---|---|
| `abis/` | One JSON file per contract — the ABI (function list) only, no bytecode |
| `addresses.json` | Deployed addresses per network (proxies + implementations + EntryPoint) |
| `dist/` | Compiled TypeScript: `proxies`, `abis`, `addresses`, and typed contracts |
| `src/types/` | Typechain-generated TypeScript bindings for all 9 contracts |

## Networks

| Network | Chain ID | Status |
|---|---|---|
| Arc testnet | 5042002 | Live — all 9 contracts verified on-chain |

Mainnet addresses will be added here when the contracts are deployed there.

## License

AGPL-3.0-only. A commercial license is available for uses that can't comply with the AGPL — see LICENSE.
