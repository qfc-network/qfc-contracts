import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying bridge contracts with account:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  // ── Configuration ───────────────────────────────────────────────────
  // In production, these would be separate EOAs or multisig participants
  const relayerAddresses = [
    deployer.address, // For demo; replace with real relayer addresses
  ];
  const quorum = 1; // For demo; use 3-of-5 in production

  // ── 1. Deploy BridgeRelayerManager ──────────────────────────────────
  console.log("\n1. Deploying BridgeRelayerManager...");
  const RelayerManager = await ethers.getContractFactory("BridgeRelayerManager");
  const relayerManager = await RelayerManager.deploy(relayerAddresses, quorum);
  await relayerManager.waitForDeployment();
  const relayerManagerAddr = await relayerManager.getAddress();
  console.log("   BridgeRelayerManager deployed to:", relayerManagerAddr);

  // ── 2. Deploy BridgeLock (source chain) ─────────────────────────────
  console.log("\n2. Deploying BridgeLock...");
  const BridgeLock = await ethers.getContractFactory("BridgeLock");
  const bridgeLock = await BridgeLock.deploy(relayerManagerAddr);
  await bridgeLock.waitForDeployment();
  const bridgeLockAddr = await bridgeLock.getAddress();
  console.log("   BridgeLock deployed to:", bridgeLockAddr);

  // ── 3. Deploy BridgeMint (QFC chain) ────────────────────────────────
  console.log("\n3. Deploying BridgeMint...");
  const BridgeMint = await ethers.getContractFactory("BridgeMint");
  const bridgeMint = await BridgeMint.deploy(relayerManagerAddr);
  await bridgeMint.waitForDeployment();
  const bridgeMintAddr = await bridgeMint.getAddress();
  console.log("   BridgeMint deployed to:", bridgeMintAddr);

  // ── 4. Deploy WrappedTokens ─────────────────────────────────────────
  console.log("\n4. Deploying Wrapped Tokens...");
  const WrappedToken = await ethers.getContractFactory("WrappedToken");

  // wETH
  const wETH = await WrappedToken.deploy("Wrapped Ether", "wETH", bridgeMintAddr, 18);
  await wETH.waitForDeployment();
  const wETHAddr = await wETH.getAddress();
  console.log("   wETH deployed to:", wETHAddr);

  // wUSDC
  const wUSDC = await WrappedToken.deploy("Wrapped USDC", "wUSDC", bridgeMintAddr, 6);
  await wUSDC.waitForDeployment();
  const wUSDCAddr = await wUSDC.getAddress();
  console.log("   wUSDC deployed to:", wUSDCAddr);

  // wBTC
  const wBTC = await WrappedToken.deploy("Wrapped Bitcoin", "wBTC", bridgeMintAddr, 8);
  await wBTC.waitForDeployment();
  const wBTCAddr = await wBTC.getAddress();
  console.log("   wBTC deployed to:", wBTCAddr);

  // ── 5. Register Wrapped Tokens ──────────────────────────────────────
  console.log("\n5. Registering wrapped tokens in BridgeMint...");

  // Use sentinel addresses for source-chain tokens (ETH native)
  const NATIVE_ETH = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
  // Placeholder addresses for USDC and BTC on source chain
  const SRC_USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // Ethereum USDC
  const SRC_WBTC = "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599"; // Ethereum WBTC

  await (await bridgeMint.registerWrappedToken(NATIVE_ETH, wETHAddr)).wait();
  console.log("   Registered wETH for native ETH");

  await (await bridgeMint.registerWrappedToken(SRC_USDC, wUSDCAddr)).wait();
  console.log("   Registered wUSDC for USDC");

  await (await bridgeMint.registerWrappedToken(SRC_WBTC, wBTCAddr)).wait();
  console.log("   Registered wBTC for WBTC");

  // ── Summary ─────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  QFC Cross-Chain Bridge — Deployment Summary");
  console.log("═══════════════════════════════════════════════════════");
  console.log("  BridgeRelayerManager:", relayerManagerAddr);
  console.log("  BridgeLock:          ", bridgeLockAddr);
  console.log("  BridgeMint:          ", bridgeMintAddr);
  console.log("  wETH:                ", wETHAddr);
  console.log("  wUSDC:               ", wUSDCAddr);
  console.log("  wBTC:                ", wBTCAddr);
  console.log("═══════════════════════════════════════════════════════\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
