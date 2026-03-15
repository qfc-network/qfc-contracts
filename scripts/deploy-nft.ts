import { ethers } from "hardhat";

/**
 * Deploy NFT ecosystem contracts to QFC testnet.
 *
 * Deployment order:
 *   1. RoyaltyRegistry
 *   2. QRCMarketplace(royaltyRegistry, feeRecipient)
 *   3. AuctionHouse(royaltyRegistry, feeRecipient)
 *   4. CollectionFactory(creationFee)
 *
 * Uses raw RPC receipt polling to work around QFC RPC quirks
 * (null fields in log entries cause ethers.js to misparse receipts).
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  const provider = deployer.provider!;
  console.log("Deploying NFT contracts with account:", deployer.address);
  console.log(
    "Balance:",
    ethers.formatEther(await provider.getBalance(deployer.address))
  );

  const nonce = await provider.getTransactionCount(deployer.address, "pending");
  console.log("Current nonce:", nonce);

  // Fee recipient = deployer (can be changed later via setFeeRecipient)
  const feeRecipient = deployer.address;

  // Creation fee for CollectionFactory (0 QFC for testnet)
  const creationFee = 0;

  // ── Helper: deploy with raw RPC receipt polling ──
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
    // Last try with longer pause
    await new Promise((r) => setTimeout(r, 10000));
    const lastTry = await provider.send("eth_getTransactionReceipt", [tx.hash]);
    if (lastTry?.contractAddress && lastTry.status === "0x1") {
      console.log("  Deployed (late receipt):", lastTry.contractAddress);
      return lastTry.contractAddress;
    }
    throw new Error(`${name} deployment timed out — no receipt after 130s`);
  }

  // ═══════════════════════════════════════════════
  // 1. Deploy RoyaltyRegistry
  // ═══════════════════════════════════════════════
  const royaltyRegistryAddr = await deploy("RoyaltyRegistry", []);

  // ═══════════════════════════════════════════════
  // 2. Deploy QRCMarketplace
  // ═══════════════════════════════════════════════
  const marketplaceAddr = await deploy("QRCMarketplace", [
    royaltyRegistryAddr,
    feeRecipient,
  ]);

  // ═══════════════════════════════════════════════
  // 3. Deploy AuctionHouse
  // ═══════════════════════════════════════════════
  const auctionHouseAddr = await deploy("AuctionHouse", [
    royaltyRegistryAddr,
    feeRecipient,
  ]);

  // ═══════════════════════════════════════════════
  // 4. Deploy CollectionFactory
  // ═══════════════════════════════════════════════
  const collectionFactoryAddr = await deploy("CollectionFactory", [creationFee]);

  // ═══════════════════════════════════════════════
  // Summary
  // ═══════════════════════════════════════════════
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  QFC NFT Ecosystem — Deployment Summary");
  console.log("═══════════════════════════════════════════════════════");
  console.log("  Network:            QFC Testnet (chainId: 9000)");
  console.log("  Deployer:           ", deployer.address);
  console.log("  Fee Recipient:      ", feeRecipient);
  console.log("  Creation Fee:       ", creationFee, "QFC");
  console.log("───────────────────────────────────────────────────────");
  console.log("  RoyaltyRegistry:    ", royaltyRegistryAddr);
  console.log("  QRCMarketplace:     ", marketplaceAddr);
  console.log("  AuctionHouse:       ", auctionHouseAddr);
  console.log("  CollectionFactory:  ", collectionFactoryAddr);
  console.log("═══════════════════════════════════════════════════════");
  console.log("\n  Environment variables for services:");
  console.log(`  NEXT_PUBLIC_MARKETPLACE_ADDRESS=${marketplaceAddr}`);
  console.log(`  NEXT_PUBLIC_AUCTION_ADDRESS=${auctionHouseAddr}`);
  console.log(`  NEXT_PUBLIC_FACTORY_ADDRESS=${collectionFactoryAddr}`);
  console.log(`  MARKETPLACE_ADDRESS=${marketplaceAddr}`);
  console.log(`  AUCTION_ADDRESS=${auctionHouseAddr}`);
  console.log(`  COLLECTION_FACTORY_ADDRESS=${collectionFactoryAddr}`);
  console.log("═══════════════════════════════════════════════════════\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
