import { ethers } from "hardhat";

/**
 * Deploy WQFC (Wrapped QFC) token on Sepolia.
 * Similar to WBTC — an ERC-20 on Ethereum representing QFC.
 *
 * Flow: User locks QFC on QFC chain → Relayer → BridgeMint on Sepolia mints WQFC
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying WQFC with account:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  // BridgeMint on Sepolia (deployed earlier)
  const bridgeMintAddr = "0xD3F854ea9f1f3B5E720bEE07aF91729572b35558";

  // Verify BridgeMint exists
  const code = await ethers.provider.getCode(bridgeMintAddr);
  if (code === "0x") {
    throw new Error("BridgeMint not found at " + bridgeMintAddr);
  }

  // WQFC already deployed
  const wqfcAddr = "0xeFA4d4559B541A3e94Ae44E5123709E2FF2b7107";
  console.log("\n1. WQFC already deployed at:", wqfcAddr);

  // 2. Register in BridgeMint — map QFC native token → WQFC
  // Use QFC-specific sentinel (0xEeee... is taken by wETH)
  // QFC native = 0x9FC0...9FC0 (derived from "QFC" as identifier)
  const NATIVE_QFC = "0x9FC09FC09FC09FC09FC09FC09FC09FC09FC09FC0";
  console.log("\n2. Registering WQFC in BridgeMint...");
  const bridgeMint = await ethers.getContractAt("BridgeMint", bridgeMintAddr);
  const tx = await bridgeMint.registerWrappedToken(NATIVE_QFC, wqfcAddr);
  await tx.wait();
  console.log("   Registered WQFC for native QFC");

  // Summary
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  WQFC (Wrapped QFC) — Deployment Summary");
  console.log("═══════════════════════════════════════════════════════");
  console.log("  Network:    ETH Sepolia");
  console.log("  WQFC:       ", wqfcAddr);
  console.log("  BridgeMint: ", bridgeMintAddr);
  console.log("  Decimals:    18");
  console.log("═══════════════════════════════════════════════════════");
  console.log("\n  Bridge flow:");
  console.log("  QFC chain: lock QFC → Relayer → Sepolia: mint WQFC");
  console.log("  Sepolia: burn WQFC → Relayer → QFC chain: unlock QFC");
  console.log("═══════════════════════════════════════════════════════\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
