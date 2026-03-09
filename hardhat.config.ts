import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-verify";

// Load environment variables
import * as dotenv from "dotenv";
dotenv.config();

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000001";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      evmVersion: "cancun",
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      chainId: 9000,
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 9000,
    },
    qfc_testnet: {
      url: process.env.QFC_TESTNET_RPC || "https://rpc.testnet.qfc.network",
      chainId: 9000,
      accounts: [PRIVATE_KEY],
    },
    qfc_mainnet: {
      url: process.env.QFC_MAINNET_RPC || "https://rpc.qfc.network",
      chainId: 9001,
      accounts: [PRIVATE_KEY],
    },
  },
  etherscan: {
    apiKey: {
      qfc_testnet: process.env.EXPLORER_API_KEY || "",
      qfc_mainnet: process.env.EXPLORER_API_KEY || "",
    },
    customChains: [
      {
        network: "qfc_testnet",
        chainId: 9000,
        urls: {
          apiURL: "https://explorer.testnet.qfc.network/api",
          browserURL: "https://explorer.testnet.qfc.network",
        },
      },
      {
        network: "qfc_mainnet",
        chainId: 9001,
        urls: {
          apiURL: "https://explorer.qfc.network/api",
          browserURL: "https://explorer.qfc.network",
        },
      },
    ],
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};

export default config;
