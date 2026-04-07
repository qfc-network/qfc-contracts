import { ethers } from "hardhat";

/**
 * Deploy BridgeLock on a new EVM chain.
 * Only deploys RelayerManager + BridgeLock (no BridgeMint/WrappedTokens).
 *
 * Usage:
 *   npx hardhat run scripts/deploy-bridge-lock.ts --network arbitrumSepolia
 *   npx hardhat run scripts/deploy-bridge-lock.ts --network polygonAmoy
 *   npx hardhat run scripts/deploy-bridge-lock.ts --network baseSepolia
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  console.log(`Deploying BridgeLock on chainId ${network.chainId}`);
  console.log("Deployer:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  const relayerAddresses = [deployer.address];
  const quorum = 1;

  // 1. Deploy BridgeRelayerManager
  console.log("\n1. Deploying BridgeRelayerManager...");
  const RelayerManager = await ethers.getContractFactory("BridgeRelayerManager");
  const relayerManager = await RelayerManager.deploy(relayerAddresses, quorum);
  await relayerManager.waitForDeployment();
  const relayerManagerAddr = await relayerManager.getAddress();
  console.log("   BridgeRelayerManager:", relayerManagerAddr);

  // 2. Deploy BridgeLock
  console.log("\n2. Deploying BridgeLock...");
  const BridgeLock = await ethers.getContractFactory("BridgeLock");
  const bridgeLock = await BridgeLock.deploy(relayerManagerAddr);
  await bridgeLock.waitForDeployment();
  const bridgeLockAddr = await bridgeLock.getAddress();
  console.log("   BridgeLock:", bridgeLockAddr);

  console.log("\n═══════════════════════════════════════");
  console.log(`  Chain ID: ${network.chainId}`);
  console.log(`  BridgeRelayerManager: ${relayerManagerAddr}`);
  console.log(`  BridgeLock:           ${bridgeLockAddr}`);
  console.log("═══════════════════════════════════════\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
