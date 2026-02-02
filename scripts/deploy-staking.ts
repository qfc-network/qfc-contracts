import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying staking contracts with account:", deployer.address);

  // Get token address from args or deploy new one
  const tokenAddress = process.env.STAKING_TOKEN_ADDRESS;
  const rewardTokenAddress = process.env.REWARD_TOKEN_ADDRESS;

  let stakingToken: string;
  let rewardToken: string;

  if (tokenAddress && rewardTokenAddress) {
    stakingToken = tokenAddress;
    rewardToken = rewardTokenAddress;
  } else {
    console.log("\nDeploying test tokens...");
    const QFCToken = await ethers.getContractFactory("QFCToken");

    const staking = await QFCToken.deploy(
      "Staking Token",
      "STAKE",
      ethers.parseEther("1000000000"),
      ethers.parseEther("1000000")
    );
    await staking.waitForDeployment();
    stakingToken = await staking.getAddress();

    const reward = await QFCToken.deploy(
      "Reward Token",
      "REWARD",
      ethers.parseEther("1000000000"),
      ethers.parseEther("10000000")
    );
    await reward.waitForDeployment();
    rewardToken = await reward.getAddress();

    console.log("Staking Token:", stakingToken);
    console.log("Reward Token:", rewardToken);
  }

  // Deploy StakingPool
  console.log("\nDeploying StakingPool...");
  const StakingPool = await ethers.getContractFactory("StakingPool");
  const pool = await StakingPool.deploy(
    stakingToken,
    rewardToken,
    ethers.parseUnits("1", 12), // reward rate: 1e12 per second per token
    7 * 24 * 60 * 60 // 7 day lock period
  );
  await pool.waitForDeployment();
  console.log("StakingPool deployed to:", await pool.getAddress());

  // Deploy RewardDistributor
  console.log("\nDeploying RewardDistributor...");
  const RewardDistributor = await ethers.getContractFactory("RewardDistributor");
  const distributor = await RewardDistributor.deploy(rewardToken);
  await distributor.waitForDeployment();
  console.log("RewardDistributor deployed to:", await distributor.getAddress());

  console.log("\n========================================");
  console.log("Staking Deployment Summary:");
  console.log("========================================");
  console.log("Staking Token:       ", stakingToken);
  console.log("Reward Token:        ", rewardToken);
  console.log("StakingPool:         ", await pool.getAddress());
  console.log("RewardDistributor:   ", await distributor.getAddress());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
