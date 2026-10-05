/**
 * arc-naming-contracts — interfaces, ABIs, types, and addresses for the
 * .arc naming service on Arc testnet.
 *
 * This package talks to contracts that are ALREADY DEPLOYED. It does not
 * deploy anything. Always use the proxy addresses in addresses.json.
 */
import addressesJson from "../addresses.json";

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------
export interface ContractDeployment {
  proxy: string;
  implementation: string | null;
  note?: string;
}
export interface NetworkAddresses {
  chainId: number;
  rpc: string;
  entryPoint: string;
  entryPointVersion: string;
  note: string;
  contracts: Record<string, ContractDeployment>;
}
export const addresses = addressesJson as Record<string, NetworkAddresses>;
export const arcTestnet = addresses.arcTestnet;
/** Shorthand: proxy addresses for Arc testnet, e.g. proxies.Registry */
export const proxies: Record<string, string> = Object.fromEntries(
  Object.entries(arcTestnet.contracts).map(([name, d]) => [name, d.proxy])
);

// ---------------------------------------------------------------------------
// ABIs (JSON, no bytecode — this is an interface package)
// ---------------------------------------------------------------------------
import AttestationRegistryAbi from "../abis/AttestationRegistry.json";
import RegistryAbi from "../abis/Registry.json";
import ResolverAbi from "../abis/Resolver.json";
import ReverseRegistrarAbi from "../abis/ReverseRegistrar.json";
import RegistrarAbi from "../abis/Registrar.json";
import BrandVaultAbi from "../abis/BrandVault.json";
import MarketplaceAbi from "../abis/Marketplace.json";
import SplitterAbi from "../abis/Splitter.json";
import ArcPaymasterAbi from "../abis/ArcPaymaster.json";

export const abis = {
  AttestationRegistry: AttestationRegistryAbi,
  Registry: RegistryAbi,
  Resolver: ResolverAbi,
  ReverseRegistrar: ReverseRegistrarAbi,
  Registrar: RegistrarAbi,
  BrandVault: BrandVaultAbi,
  Marketplace: MarketplaceAbi,
  Splitter: SplitterAbi,
  ArcPaymaster: ArcPaymasterAbi,
} as const;

export {
  AttestationRegistryAbi,
  RegistryAbi,
  ResolverAbi,
  ReverseRegistrarAbi,
  RegistrarAbi,
  BrandVaultAbi,
  MarketplaceAbi,
  SplitterAbi,
  ArcPaymasterAbi,
};

// ---------------------------------------------------------------------------
// Typed contracts (re-exported from the typechain bindings)
// ---------------------------------------------------------------------------
export type { AttestationRegistry } from "./types/AttestationRegistry";
export type { Registry } from "./types/Registry";
export type { Splitter } from "./types/Splitter";
export type { BrandVault } from "./types/BrandVault.sol/BrandVault";
export type { Marketplace } from "./types/Marketplace.sol/Marketplace";
export type { ArcPaymaster } from "./types/Paymaster.sol/ArcPaymaster";
export type { Registrar } from "./types/Registrar.sol/Registrar";
export type { Resolver } from "./types/Resolver.sol/Resolver";
export type { ReverseRegistrar } from "./types/ReverseRegistrar.sol/ReverseRegistrar";
