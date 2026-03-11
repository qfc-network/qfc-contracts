import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying inference contracts with:", deployer.address);

  // 1. ModelRegistry
  const ModelRegistry = await ethers.getContractFactory("ModelRegistry");
  const modelRegistry = await ModelRegistry.deploy();
  await modelRegistry.waitForDeployment();
  const modelRegistryAddr = await modelRegistry.getAddress();
  console.log("ModelRegistry:", modelRegistryAddr);

  // 2. MinerRegistry (min stake = 1 QFC)
  const minStake = ethers.parseEther("1");
  const MinerRegistry = await ethers.getContractFactory("MinerRegistry");
  const minerRegistry = await MinerRegistry.deploy(minStake);
  await minerRegistry.waitForDeployment();
  const minerRegistryAddr = await minerRegistry.getAddress();
  console.log("MinerRegistry:", minerRegistryAddr);

  // 3. FeeEscrow (2.5% protocol fee)
  const FeeEscrow = await ethers.getContractFactory("FeeEscrow");
  const feeEscrow = await FeeEscrow.deploy(250, deployer.address);
  await feeEscrow.waitForDeployment();
  const feeEscrowAddr = await feeEscrow.getAddress();
  console.log("FeeEscrow:", feeEscrowAddr);

  // 4. TaskRegistry
  const TaskRegistry = await ethers.getContractFactory("TaskRegistry");
  const taskRegistry = await TaskRegistry.deploy(
    modelRegistryAddr,
    minerRegistryAddr,
    feeEscrowAddr
  );
  await taskRegistry.waitForDeployment();
  const taskRegistryAddr = await taskRegistry.getAddress();
  console.log("TaskRegistry:", taskRegistryAddr);

  // 5. ResultVerifier (slash = 0.5 QFC, challenge stake = 0.1 QFC)
  const ResultVerifier = await ethers.getContractFactory("ResultVerifier");
  const resultVerifier = await ResultVerifier.deploy(
    taskRegistryAddr,
    minerRegistryAddr,
    ethers.parseEther("0.5"),
    ethers.parseEther("0.1")
  );
  await resultVerifier.waitForDeployment();
  const resultVerifierAddr = await resultVerifier.getAddress();
  console.log("ResultVerifier:", resultVerifierAddr);

  // 6. Transfer FeeEscrow ownership to TaskRegistry
  await feeEscrow.transferOwnership(taskRegistryAddr);
  console.log("FeeEscrow ownership transferred to TaskRegistry");

  // 7. Authorize TaskRegistry and ResultVerifier on MinerRegistry
  await minerRegistry.authorizeCaller(taskRegistryAddr);
  await minerRegistry.authorizeCaller(resultVerifierAddr);
  console.log("TaskRegistry and ResultVerifier authorized on MinerRegistry");

  // 8. Register default models
  await modelRegistry.registerModel(
    "llama-3-70b",
    "Llama 3 70B",
    ethers.parseEther("0.01"),
    2
  );
  await modelRegistry.registerModel(
    "llama-3-8b",
    "Llama 3 8B",
    ethers.parseEther("0.002"),
    1
  );
  console.log("Default models registered");

  console.log("\n--- Deployment Summary ---");
  console.log("ModelRegistry:   ", modelRegistryAddr);
  console.log("MinerRegistry:   ", minerRegistryAddr);
  console.log("FeeEscrow:       ", feeEscrowAddr);
  console.log("TaskRegistry:    ", taskRegistryAddr);
  console.log("ResultVerifier:  ", resultVerifierAddr);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
