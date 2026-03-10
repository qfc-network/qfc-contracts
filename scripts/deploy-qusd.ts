import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying QUSD contracts with account:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "QFC");

  // 1. Deploy PriceFeed with initial QFC/USD price ($2.00 = 200_000_000)
  const initialPrice = 200_000_000n; // $2.00 with 8 decimals
  const PriceFeed = await ethers.getContractFactory("PriceFeed");
  const priceFeed = await PriceFeed.deploy(initialPrice);
  await priceFeed.waitForDeployment();
  const priceFeedAddr = await priceFeed.getAddress();
  console.log("✅ PriceFeed deployed to:", priceFeedAddr);

  // 2. Deploy QUSDToken
  const QUSDToken = await ethers.getContractFactory("QUSDToken");
  const qusd = await QUSDToken.deploy();
  await qusd.waitForDeployment();
  const qusdAddr = await qusd.getAddress();
  console.log("✅ QUSDToken deployed to:", qusdAddr);

  // 3. Deploy CDPVault
  const CDPVault = await ethers.getContractFactory("CDPVault");
  const vault = await CDPVault.deploy(qusdAddr, priceFeedAddr);
  await vault.waitForDeployment();
  const vaultAddr = await vault.getAddress();
  console.log("✅ CDPVault deployed to:", vaultAddr);

  // 4. Set vault as the authorized minter/burner on QUSDToken
  await qusd.setVault(vaultAddr);
  console.log("✅ CDPVault set as QUSD vault");

  // 5. Deploy Liquidator helper
  const Liquidator = await ethers.getContractFactory("Liquidator");
  const liquidator = await Liquidator.deploy(vaultAddr);
  await liquidator.waitForDeployment();
  const liquidatorAddr = await liquidator.getAddress();
  console.log("✅ Liquidator deployed to:", liquidatorAddr);

  console.log("\n📋 Deployment Summary:");
  console.log("========================");
  console.log("PriceFeed:  ", priceFeedAddr);
  console.log("QUSDToken:  ", qusdAddr);
  console.log("CDPVault:   ", vaultAddr);
  console.log("Liquidator: ", liquidatorAddr);
  console.log("========================");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
