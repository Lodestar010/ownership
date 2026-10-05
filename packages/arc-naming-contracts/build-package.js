/**
 * Builds the package content from Hardhat artifacts + typechain types.
 * Run from the naming-service project root: node packages/arc-naming-contracts/build-package.js
 * Read-only on artifacts/ and typechain-types/ — only writes into packages/arc-naming-contracts/.
 */
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..", "..");
const PKG = path.join(ROOT, "packages", "arc-naming-contracts");

// contract name -> artifact path (relative to artifacts/)
const CONTRACTS = {
  AttestationRegistry: "contracts/AttestationRegistry.sol/AttestationRegistry.json",
  Registry: "contracts/Registry.sol/Registry.json",
  Resolver: "contracts/Resolver.sol/Resolver.json",
  ReverseRegistrar: "contracts/ReverseRegistrar.sol/ReverseRegistrar.json",
  Registrar: "contracts/Registrar.sol/Registrar.json",
  BrandVault: "contracts/BrandVault.sol/BrandVault.json",
  Marketplace: "contracts/Marketplace.sol/Marketplace.json",
  Splitter: "contracts/Splitter.sol/Splitter.json",
  ArcPaymaster: "contracts/Paymaster.sol/ArcPaymaster.json",
};

function main() {
  // 1. ABIs (abi only — no bytecode; this is an interface package)
  const abiDir = path.join(PKG, "abis");
  fs.mkdirSync(abiDir, { recursive: true });
  for (const [name, artPath] of Object.entries(CONTRACTS)) {
    const art = JSON.parse(fs.readFileSync(path.join(ROOT, "artifacts", artPath), "utf8"));
    fs.writeFileSync(path.join(abiDir, `${name}.json`), JSON.stringify(art.abi, null, 2) + "\n");
    console.log(`abi: ${name}.json (${art.abi.length} entries)`);
  }

  // 2. TypeScript types: copy typechain contract types (minus test contracts)
  const srcTypes = path.join(PKG, "src", "types");
  fs.rmSync(srcTypes, { recursive: true, force: true });
  const copyDir = (src, dst, skip) => {
    fs.mkdirSync(dst, { recursive: true });
    for (const e of fs.readdirSync(src, { withFileTypes: true })) {
      if (skip && skip.includes(e.name)) continue;
      if (e.isDirectory()) copyDir(path.join(src, e.name), path.join(dst, e.name), skip);
      else fs.copyFileSync(path.join(src, e.name), path.join(dst, e.name));
    }
  };
  copyDir(path.join(ROOT, "typechain-types", "contracts"), srcTypes, ["test"]);
  // the copied index.ts references ./test which we excluded — strip it
  const idxPath = path.join(srcTypes, "index.ts");
  const idx = fs.readFileSync(idxPath, "utf8")
    .split("\n")
    .filter((l) => !l.includes("./test") && !l.includes("{ test }"))
    .join("\n");
  fs.writeFileSync(idxPath, idx);
  // typechain's common.ts lives one level up from contracts/
  fs.copyFileSync(
    path.join(ROOT, "typechain-types", "common.ts"),
    path.join(PKG, "src", "common.ts")
  );
  console.log("types: copied typechain contract types (excluding test/)");

  console.log("done.");
}

main();
