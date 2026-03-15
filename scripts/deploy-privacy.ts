import { ethers } from "hardhat";

/**
 * Deploy Privacy Pool contracts to QFC testnet.
 *
 * Deployment order:
 *   1. Poseidon hasher (from circomlibjs bytecode)
 *   2. Groth16Verifier (standard withdrawal)
 *   3. ComplianceGroth16Verifier (compliance withdrawal)
 *   4. ShieldedPoolV2 (main privacy pool)
 *   5. AssociationSet (compliance address sets)
 *   6. ComplianceVerifier (compliance proof checker)
 *   7. StealthAddress (stealth address registry)
 *
 * Uses raw RPC receipt polling to work around QFC RPC quirks.
 */

const poseidonContract = require("circomlibjs").poseidonContract;

async function main() {
  const [deployer] = await ethers.getSigners();
  const provider = deployer.provider!;
  console.log("🛡️  Deploying Privacy Pool contracts");
  console.log("   Account:", deployer.address);
  console.log("   Balance:", ethers.formatEther(await provider.getBalance(deployer.address)), "QFC");
  console.log("");

  // qUSD token address (must be deployed already)
  const QUSD_ADDRESS = process.env.QUSD_TOKEN_ADDRESS || "";
  if (!QUSD_ADDRESS) {
    console.error("❌ Set QUSD_TOKEN_ADDRESS env var to the deployed qUSD token address");
    process.exitCode = 1;
    return;
  }

  // ── Helper: deploy with raw RPC receipt polling ──
  async function deploy(name: string, args: unknown[]): Promise<string> {
    console.log(`Deploying ${name}...`);
    const Factory = await ethers.getContractFactory(name);
    const deployTx = await Factory.getDeployTransaction(...args);
    const tx = await deployer.sendTransaction({ data: deployTx.data });
    console.log("  tx:", tx.hash);

    for (let i = 0; i < 60; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      const raw = await provider.send("eth_getTransactionReceipt", [tx.hash]);
      if (raw?.status === "0x1" && raw.contractAddress) {
        console.log("  ✅", raw.contractAddress);
        return raw.contractAddress;
      }
      if (raw?.status === "0x0") {
        throw new Error(`${name} deployment reverted`);
      }
    }
    throw new Error(`${name} deployment timed out`);
  }

  // Deploy raw bytecode (for Poseidon hasher)
  async function deployBytecode(name: string, abi: any[], bytecode: string): Promise<string> {
    console.log(`Deploying ${name} (bytecode)...`);
    const factory = new ethers.ContractFactory(abi, bytecode, deployer);
    const deployTx = await factory.getDeployTransaction();
    const tx = await deployer.sendTransaction({ data: deployTx.data });
    console.log("  tx:", tx.hash);

    for (let i = 0; i < 60; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      const raw = await provider.send("eth_getTransactionReceipt", [tx.hash]);
      if (raw?.status === "0x1" && raw.contractAddress) {
        console.log("  ✅", raw.contractAddress);
        return raw.contractAddress;
      }
      if (raw?.status === "0x0") {
        throw new Error(`${name} deployment reverted`);
      }
    }
    throw new Error(`${name} deployment timed out`);
  }

  // ═══════════════════════════════════════════════
  // 1. Poseidon Hasher (from circomlibjs)
  // ═══════════════════════════════════════════════
  const poseidonBytecode = poseidonContract.createCode(2);
  const poseidonAbi = poseidonContract.generateABI(2);
  const poseidonAddr = await deployBytecode("Poseidon(2) Hasher", poseidonAbi, poseidonBytecode);

  // ═══════════════════════════════════════════════
  // 2. Groth16Verifier (standard withdrawal)
  // ═══════════════════════════════════════════════
  const verifierAddr = await deploy("Groth16Verifier", []);

  // ═══════════════════════════════════════════════
  // 3. ComplianceGroth16Verifier
  // ═══════════════════════════════════════════════
  const complianceVerifierAddr = await deploy("ComplianceGroth16Verifier", []);

  // ═══════════════════════════════════════════════
  // 4. ShieldedPoolV2 (main privacy pool)
  // ═══════════════════════════════════════════════
  const poolAddr = await deploy("ShieldedPoolV2", [QUSD_ADDRESS, verifierAddr, poseidonAddr]);

  // ═══════════════════════════════════════════════
  // 5. AssociationSet
  // ═══════════════════════════════════════════════
  const assocSetAddr = await deploy("AssociationSet", [deployer.address]);

  // ═══════════════════════════════════════════════
  // 6. ComplianceVerifier
  // ═══════════════════════════════════════════════
  const compVerifierAddr = await deploy("ComplianceVerifier", [assocSetAddr]);

  // ═══════════════════════════════════════════════
  // 7. StealthAddress
  // ═══════════════════════════════════════════════
  const stealthAddr = await deploy("StealthAddress", []);

  // ═══════════════════════════════════════════════
  // Summary
  // ═══════════════════════════════════════════════
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  🛡️  QFC Privacy Pool — Deployment Summary");
  console.log("═══════════════════════════════════════════════════════");
  console.log("  Network:                    QFC Testnet (chainId: 9000)");
  console.log("  Deployer:                  ", deployer.address);
  console.log("  qUSD Token:                ", QUSD_ADDRESS);
  console.log("───────────────────────────────────────────────────────");
  console.log("  Poseidon(2) Hasher:        ", poseidonAddr);
  console.log("  Groth16Verifier:           ", verifierAddr);
  console.log("  ComplianceGroth16Verifier: ", complianceVerifierAddr);
  console.log("  ShieldedPoolV2:            ", poolAddr);
  console.log("  AssociationSet:            ", assocSetAddr);
  console.log("  ComplianceVerifier:        ", compVerifierAddr);
  console.log("  StealthAddress:            ", stealthAddr);
  console.log("═══════════════════════════════════════════════════════");
  console.log("\n  Relayer environment variables:");
  console.log(`  SHIELDED_POOL_ADDRESS=${poolAddr}`);
  console.log(`  RPC_URL=https://rpc.testnet.qfc.network`);
  console.log(`  RELAYER_PORT=3290`);
  console.log("");
  console.log("  Frontend environment variables:");
  console.log(`  NEXT_PUBLIC_SHIELDED_POOL=${poolAddr}`);
  console.log(`  NEXT_PUBLIC_STEALTH_REGISTRY=${stealthAddr}`);
  console.log(`  NEXT_PUBLIC_ASSOCIATION_SET=${assocSetAddr}`);
  console.log(`  NEXT_PUBLIC_COMPLIANCE_VERIFIER=${compVerifierAddr}`);
  console.log(`  NEXT_PUBLIC_RELAYER_URL=http://localhost:3290`);
  console.log("═══════════════════════════════════════════════════════\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
