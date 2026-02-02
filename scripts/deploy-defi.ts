import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying DeFi contracts with account:", deployer.address);

  // Deploy test tokens for the swap pool
  console.log("\nDeploying test tokens...");
  const QFCToken = await ethers.getContractFactory("QFCToken");

  const tokenA = await QFCToken.deploy(
    "Token A",
    "TKNA",
    ethers.parseEther("1000000000"),
    ethers.parseEther("1000000")
  );
  await tokenA.waitForDeployment();
  console.log("Token A:", await tokenA.getAddress());

  const tokenB = await QFCToken.deploy(
    "Token B",
    "TKNB",
    ethers.parseEther("1000000000"),
    ethers.parseEther("1000000")
  );
  await tokenB.waitForDeployment();
  console.log("Token B:", await tokenB.getAddress());

  // Deploy SimpleSwap
  console.log("\nDeploying SimpleSwap...");
  const SimpleSwap = await ethers.getContractFactory("SimpleSwap");
  const swap = await SimpleSwap.deploy(
    await tokenA.getAddress(),
    await tokenB.getAddress()
  );
  await swap.waitForDeployment();
  console.log("SimpleSwap deployed to:", await swap.getAddress());

  // Deploy Vault for Token A
  console.log("\nDeploying Vault...");
  const Vault = await ethers.getContractFactory("Vault");
  const vault = await Vault.deploy(
    await tokenA.getAddress(),
    "QFC Vault Token A",
    "vTKNA",
    200 // 2% management fee
  );
  await vault.waitForDeployment();
  console.log("Vault deployed to:", await vault.getAddress());

  console.log("\n========================================");
  console.log("DeFi Deployment Summary:");
  console.log("========================================");
  console.log("Token A:     ", await tokenA.getAddress());
  console.log("Token B:     ", await tokenB.getAddress());
  console.log("SimpleSwap:  ", await swap.getAddress());
  console.log("Vault:       ", await vault.getAddress());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
