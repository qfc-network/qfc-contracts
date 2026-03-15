import { ethers } from "hardhat";

/**
 * Deploy bridge contracts to QFC chain.
 * Works around QFC RPC returning null fields in log entries
 * which causes ethers.js to misinterpret successful receipts as failures.
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  const provider = deployer.provider!;
  console.log("Deploying with account:", deployer.address);
  console.log("Balance:", ethers.formatEther(await provider.getBalance(deployer.address)));

  const nonce = await provider.getTransactionCount(deployer.address, "pending");
  console.log("Current nonce:", nonce);

  // BridgeRelayerManager already deployed (first deploy tx)
  const relayerManagerAddr = "0xc216c986fc2e27e18ad8260ee4e64beab394563d";
  console.log("\nBridgeRelayerManager (already deployed):", relayerManagerAddr);

  // Verify it exists
  const code = await provider.getCode(relayerManagerAddr);
  if (code === "0x") {
    throw new Error("BridgeRelayerManager not found at " + relayerManagerAddr);
  }
  console.log("  Verified: contract exists (%d bytes)", (code.length - 2) / 2);

  // Helper: deploy and wait manually via raw RPC receipt polling
  async function deploy(name: string, args: unknown[]): Promise<string> {
    console.log(`\nDeploying ${name}...`);
    const Factory = await ethers.getContractFactory(name);
    const deployTx = await Factory.getDeployTransaction(...args);

    const tx = await deployer.sendTransaction({ data: deployTx.data });
    console.log("  tx:", tx.hash);

    // Poll raw RPC for receipt (bypasses ethers.js receipt parsing)
    for (let i = 0; i < 60; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      const raw = await provider.send("eth_getTransactionReceipt", [tx.hash]);
      if (raw) {
        if (raw.status !== "0x1") {
          throw new Error(`${name} deployment reverted (status: ${raw.status})`);
        }
        if (raw.contractAddress) {
          console.log("  Deployed:", raw.contractAddress);
          return raw.contractAddress;
        }
      }
    }
    // One more try with a longer pause
    await new Promise((r) => setTimeout(r, 10000));
    const lastTry = await provider.send("eth_getTransactionReceipt", [tx.hash]);
    if (lastTry?.contractAddress && lastTry.status === "0x1") {
      console.log("  Deployed (late receipt):", lastTry.contractAddress);
      return lastTry.contractAddress;
    }
    throw new Error(`${name} deployment timed out — no receipt after 130s`);
  }

  // ── BridgeLock (already deployed) ──
  const bridgeLockAddr = "0x47ea0e0cdc65cc1f4f7b21f922219139f23e1a27";
  console.log("\nBridgeLock (already deployed):", bridgeLockAddr);

  // ── BridgeMint (already deployed) ──
  const bridgeMintAddr = "0x2fb46fab5153b2f1047f033e1f8a79c483a9a048";
  console.log("BridgeMint (already deployed):", bridgeMintAddr);

  // ── Deploy WrappedTokens ──
  const wETHAddr = await deploy("WrappedToken", ["Wrapped Ether", "wETH", bridgeMintAddr, 18]);
  const wUSDCAddr = await deploy("WrappedToken", ["Wrapped USDC", "wUSDC", bridgeMintAddr, 6]);
  const wBTCAddr = await deploy("WrappedToken", ["Wrapped Bitcoin", "wBTC", bridgeMintAddr, 8]);

  // ── Register wrapped tokens in BridgeMint ──
  console.log("\nRegistering wrapped tokens...");
  const bridgeMint = await ethers.getContractAt("BridgeMint", bridgeMintAddr);

  const NATIVE_ETH = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
  const SRC_USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const SRC_WBTC = "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599";

  const registrations = [
    { src: NATIVE_ETH, wrapped: wETHAddr, label: "wETH ← native ETH" },
    { src: SRC_USDC, wrapped: wUSDCAddr, label: "wUSDC ← USDC" },
    { src: SRC_WBTC, wrapped: wBTCAddr, label: "wBTC ← WBTC" },
  ];

  for (const reg of registrations) {
    const tx = await bridgeMint.registerWrappedToken(reg.src, reg.wrapped);
    console.log("  Registering %s ... tx: %s", reg.label, tx.hash);
    // Wait for confirmation
    for (let i = 0; i < 30; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      const raw = await provider.send("eth_getTransactionReceipt", [tx.hash]);
      if (raw && raw.status === "0x1") {
        console.log("  Done");
        break;
      }
    }
  }

  // ── Summary ──
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  QFC Cross-Chain Bridge — Deployment Summary");
  console.log("═══════════════════════════════════════════════════════");
  console.log("  BridgeRelayerManager:", relayerManagerAddr);
  console.log("  BridgeLock:          ", bridgeLockAddr);
  console.log("  BridgeMint:          ", bridgeMintAddr);
  console.log("  wETH:                ", wETHAddr);
  console.log("  wUSDC:               ", wUSDCAddr);
  console.log("  wBTC:                ", wBTCAddr);
  console.log("═══════════════════════════════════════════════════════");
  console.log("\nSet BRIDGE_QFC_ADDRESS=%s in qfc-bridge/.env", bridgeLockAddr);
  console.log("═══════════════════════════════════════════════════════\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
