import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying Yield Aggregator contracts with account:", deployer.address);

  // Deploy underlying asset token
  const QFCToken = await ethers.getContractFactory("QFCToken");
  const token = await QFCToken.deploy(
    "QFC Token",
    "QFC",
    ethers.parseEther("1000000000"),
    ethers.parseEther("1000000")
  );
  await token.waitForDeployment();
  const tokenAddress = await token.getAddress();
  console.log("QFC Token deployed to:", tokenAddress);

  // Deploy YieldVault
  const YieldVault = await ethers.getContractFactory("YieldVault");
  const vault = await YieldVault.deploy(
    tokenAddress,
    "QFC Yield Vault",
    "yvQFC",
    deployer.address // feeRecipient
  );
  await vault.waitForDeployment();
  const vaultAddress = await vault.getAddress();
  console.log("YieldVault deployed to:", vaultAddress);

  console.log("\n--- Deployment Summary ---");
  console.log("Asset Token:", tokenAddress);
  console.log("YieldVault:", vaultAddress);
  console.log("Fee Recipient:", deployer.address);
  console.log("Performance Fee: 10%");
  console.log("\nNote: Add strategies via vault.addStrategy(strategyAddress, allocationBps)");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
