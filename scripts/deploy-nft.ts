import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying NFT Marketplace contracts with account:", deployer.address);

  // Deploy RoyaltyRegistry
  console.log("\nDeploying RoyaltyRegistry...");
  const RoyaltyRegistry = await ethers.getContractFactory("RoyaltyRegistry");
  const royaltyRegistry = await RoyaltyRegistry.deploy();
  await royaltyRegistry.waitForDeployment();
  console.log("RoyaltyRegistry deployed to:", await royaltyRegistry.getAddress());

  // Deploy QRCMarketplace
  console.log("\nDeploying QRCMarketplace...");
  const QRCMarketplace = await ethers.getContractFactory("QRCMarketplace");
  const marketplace = await QRCMarketplace.deploy(
    await royaltyRegistry.getAddress(),
    deployer.address // fee recipient
  );
  await marketplace.waitForDeployment();
  console.log("QRCMarketplace deployed to:", await marketplace.getAddress());

  // Deploy AuctionHouse
  console.log("\nDeploying AuctionHouse...");
  const AuctionHouse = await ethers.getContractFactory("AuctionHouse");
  const auctionHouse = await AuctionHouse.deploy(
    await royaltyRegistry.getAddress(),
    deployer.address // fee recipient
  );
  await auctionHouse.waitForDeployment();
  console.log("AuctionHouse deployed to:", await auctionHouse.getAddress());

  // Deploy CollectionFactory
  console.log("\nDeploying CollectionFactory...");
  const CollectionFactory = await ethers.getContractFactory("CollectionFactory");
  const factory = await CollectionFactory.deploy(
    ethers.parseEther("0.01") // creation fee
  );
  await factory.waitForDeployment();
  console.log("CollectionFactory deployed to:", await factory.getAddress());

  console.log("\n========================================");
  console.log("NFT Marketplace Deployment Summary:");
  console.log("========================================");
  console.log("RoyaltyRegistry:  ", await royaltyRegistry.getAddress());
  console.log("QRCMarketplace:   ", await marketplace.getAddress());
  console.log("AuctionHouse:     ", await auctionHouse.getAddress());
  console.log("CollectionFactory:", await factory.getAddress());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
