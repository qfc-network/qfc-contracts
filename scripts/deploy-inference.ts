import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying inference contracts with account:", deployer.address);

  // 1. Deploy ModelRegistry
  const ModelRegistry = await ethers.getContractFactory("ModelRegistry");
  const modelRegistry = await ModelRegistry.deploy();
  await modelRegistry.waitForDeployment();
  const modelRegistryAddr = await modelRegistry.getAddress();
  console.log("ModelRegistry deployed to:", modelRegistryAddr);

  // 2. Deploy MinerRegistry
  const MinerRegistry = await ethers.getContractFactory("MinerRegistry");
  const minerRegistry = await MinerRegistry.deploy();
  await minerRegistry.waitForDeployment();
  const minerRegistryAddr = await minerRegistry.getAddress();
  console.log("MinerRegistry deployed to:", minerRegistryAddr);

  // 3. Deploy FeeEscrow
  const FeeEscrow = await ethers.getContractFactory("FeeEscrow");
  const feeEscrow = await FeeEscrow.deploy();
  await feeEscrow.waitForDeployment();
  const feeEscrowAddr = await feeEscrow.getAddress();
  console.log("FeeEscrow deployed to:", feeEscrowAddr);

  // 4. Deploy TaskRegistry
  const TaskRegistry = await ethers.getContractFactory("TaskRegistry");
  const taskRegistry = await TaskRegistry.deploy(
    modelRegistryAddr,
    minerRegistryAddr,
    feeEscrowAddr
  );
  await taskRegistry.waitForDeployment();
  const taskRegistryAddr = await taskRegistry.getAddress();
  console.log("TaskRegistry deployed to:", taskRegistryAddr);

  // 5. Wire contracts together
  console.log("\nWiring contracts...");
  await minerRegistry.setTaskRegistry(taskRegistryAddr);
  console.log("MinerRegistry → TaskRegistry linked");

  await feeEscrow.setTaskRegistry(taskRegistryAddr);
  console.log("FeeEscrow → TaskRegistry linked");

  // Set deployer as router for convenience
  await taskRegistry.setRouter(deployer.address);
  console.log("TaskRegistry router set to deployer");

  // 6. Register initial models
  console.log("\nRegistering initial models...");

  const llama3_8b = ethers.id("llama3-8b");
  await modelRegistry.registerModel(
    llama3_8b,
    "llama3-8b",
    1,
    ethers.parseEther("0.01")
  );
  console.log("Registered: llama3-8b (tier1, 0.01 QFC)");

  const llama3_70b = ethers.id("llama3-70b");
  await modelRegistry.registerModel(
    llama3_70b,
    "llama3-70b",
    2,
    ethers.parseEther("0.05")
  );
  console.log("Registered: llama3-70b (tier2, 0.05 QFC)");

  const whisper = ethers.id("whisper-large-v3");
  await modelRegistry.registerModel(
    whisper,
    "whisper-large-v3",
    1,
    ethers.parseEther("0.005")
  );
  console.log("Registered: whisper-large-v3 (tier1, 0.005 QFC)");

  // Summary
  console.log("\n========================================");
  console.log("Inference Marketplace Deployment Summary");
  console.log("========================================");
  console.log("ModelRegistry: ", modelRegistryAddr);
  console.log("MinerRegistry: ", minerRegistryAddr);
  console.log("FeeEscrow:     ", feeEscrowAddr);
  console.log("TaskRegistry:  ", taskRegistryAddr);
  console.log("========================================");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
