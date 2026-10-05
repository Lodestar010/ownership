import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      // Arc rejects PUSH0 (default from solc >= 0.8.20 / Shanghai).
      // "paris" (or earlier) keeps deploys working on Arc.
      evmVersion: "paris",
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    hardhat: {},
    arcTestnet: {
      url: "https://rpc.testnet.arc.network",
      chainId: 5042002,
      // Douglas deploys from his own wallet. Private key is read from the
      // environment at deploy time — never committed, never held by anyone else.
      accounts: process.env.DEPLOYER_KEY ? [process.env.DEPLOYER_KEY] : [],
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
  },
};

export default config;
