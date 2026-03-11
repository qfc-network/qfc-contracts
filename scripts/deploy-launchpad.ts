import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying launchpad contracts with account:", deployer.address);

  // Deploy VestingSchedule
  const VestingSchedule = await ethers.getContractFactory("VestingSchedule");
  const vesting = await VestingSchedule.deploy();
  await vesting.waitForDeployment();
  console.log("VestingSchedule deployed to:", await vesting.getAddress());

  // Deploy LaunchpadFactory
  const LaunchpadFactory = await ethers.getContractFactory("LaunchpadFactory");
  const factory = await LaunchpadFactory.deploy();
  await factory.waitForDeployment();
  console.log("LaunchpadFactory deployed to:", await factory.getAddress());

  // Deploy individual launchpad contracts via factory
  const txFairLaunch = await factory.deployFairLaunch();
  const receiptFL = await txFairLaunch.wait();
  console.log("FairLaunch deployed via factory");

  const txWhitelistSale = await factory.deployWhitelistSale();
  const receiptWS = await txWhitelistSale.wait();
  console.log("WhitelistSale deployed via factory");

  const txDutchAuction = await factory.deployDutchAuction();
  const receiptDA = await txDutchAuction.wait();
  console.log("DutchAuction deployed via factory");

  // Log summary
  console.log("\n========== Launchpad Deployment Summary ==========");
  console.log("VestingSchedule:  ", await vesting.getAddress());
  console.log("LaunchpadFactory: ", await factory.getAddress());
  console.log("FairLaunch:       ", await factory.fairLaunches(0));
  console.log("WhitelistSale:    ", await factory.whitelistSales(0));
  console.log("DutchAuction:     ", await factory.dutchAuctions(0));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
