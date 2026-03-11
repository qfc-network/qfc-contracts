import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying liquid staking contracts with account:", deployer.address);

  // Deploy LiquidStaking (automatically deploys StQFC)
  console.log("\nDeploying LiquidStaking...");
  const LiquidStaking = await ethers.getContractFactory("LiquidStaking");
  const liquidStaking = await LiquidStaking.deploy();
  await liquidStaking.waitForDeployment();
  console.log("LiquidStaking deployed to:", await liquidStaking.getAddress());

  const stQFCAddress = await liquidStaking.stQFC();
  console.log("StQFC token deployed to:", stQFCAddress);

  console.log("\n========================================");
  console.log("Liquid Staking Deployment Summary:");
  console.log("========================================");
  console.log("LiquidStaking:  ", await liquidStaking.getAddress());
  console.log("StQFC Token:    ", stQFCAddress);
  console.log("Exchange Rate:  ", "1:1 (initial)");
  console.log("Cooldown Period:", "7 days");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
