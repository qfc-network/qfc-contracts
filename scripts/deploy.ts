import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  // Deploy QFCToken
  console.log("\nDeploying QFCToken...");
  const QFCToken = await ethers.getContractFactory("QFCToken");
  const token = await QFCToken.deploy(
    "QFC Token",
    "QFC",
    ethers.parseEther("1000000000"), // 1 billion cap
    ethers.parseEther("100000000")   // 100 million initial supply
  );
  await token.waitForDeployment();
  console.log("QFCToken deployed to:", await token.getAddress());

  // Deploy QFCNFT
  console.log("\nDeploying QFCNFT...");
  const QFCNFT = await ethers.getContractFactory("QFCNFT");
  const nft = await QFCNFT.deploy(
    "QFC NFT",
    "QFCNFT",
    10000, // max supply
    ethers.parseEther("0.1"), // mint price
    "https://nft.qfc.network/metadata/"
  );
  await nft.waitForDeployment();
  console.log("QFCNFT deployed to:", await nft.getAddress());

  // Deploy Multicall
  console.log("\nDeploying Multicall...");
  const Multicall = await ethers.getContractFactory("Multicall");
  const multicall = await Multicall.deploy();
  await multicall.waitForDeployment();
  console.log("Multicall deployed to:", await multicall.getAddress());

  // Deploy Create2Factory
  console.log("\nDeploying Create2Factory...");
  const Create2Factory = await ethers.getContractFactory("Create2Factory");
  const factory = await Create2Factory.deploy();
  await factory.waitForDeployment();
  console.log("Create2Factory deployed to:", await factory.getAddress());

  console.log("\n========================================");
  console.log("Deployment Summary:");
  console.log("========================================");
  console.log("QFCToken:       ", await token.getAddress());
  console.log("QFCNFT:         ", await nft.getAddress());
  console.log("Multicall:      ", await multicall.getAddress());
  console.log("Create2Factory: ", await factory.getAddress());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
