import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying perpetuals with:", deployer.address);

  // 1. Deploy QUSD (mock stablecoin for margin)
  const MockToken = await ethers.getContractFactory("QFCToken");
  const qusd = await MockToken.deploy(
    "QFC USD",
    "QUSD",
    ethers.parseEther("1000000000"), // 1B cap
    ethers.parseEther("100000000")   // 100M initial
  );
  await qusd.waitForDeployment();
  const qusdAddr = await qusd.getAddress();
  console.log("QUSD deployed:", qusdAddr);

  // 2. Deploy PriceOracle
  const Oracle = await ethers.getContractFactory("PriceOracle");
  const oracle = await Oracle.deploy();
  await oracle.waitForDeployment();
  const oracleAddr = await oracle.getAddress();
  console.log("PriceOracle deployed:", oracleAddr);

  // Set initial prices
  await oracle.setPrices(
    ["QFC", "TTK", "QDOGE"],
    [
      ethers.parseEther("25"),     // QFC = $25
      ethers.parseEther("100"),    // TTK = $100
      ethers.parseEther("0.001"),  // QDOGE = $0.001
    ]
  );
  console.log("Initial prices set");

  // 3. Deploy LiquidityPool
  const Pool = await ethers.getContractFactory("LiquidityPool");
  const pool = await Pool.deploy(qusdAddr);
  await pool.waitForDeployment();
  const poolAddr = await pool.getAddress();
  console.log("LiquidityPool deployed:", poolAddr);

  // 4. Deploy PositionManager
  const PM = await ethers.getContractFactory("PositionManager");
  const positionManager = await PM.deploy(qusdAddr, oracleAddr);
  await positionManager.waitForDeployment();
  const pmAddr = await positionManager.getAddress();
  console.log("PositionManager deployed:", pmAddr);

  // 5. Deploy FundingRate
  const FR = await ethers.getContractFactory("FundingRate");
  const fundingRate = await FR.deploy();
  await fundingRate.waitForDeployment();
  const frAddr = await fundingRate.getAddress();
  console.log("FundingRate deployed:", frAddr);

  // 6. Deploy PerpRouter
  const Router = await ethers.getContractFactory("PerpRouter");
  const router = await Router.deploy(qusdAddr, pmAddr, poolAddr, deployer.address);
  await router.waitForDeployment();
  const routerAddr = await router.getAddress();
  console.log("PerpRouter deployed:", routerAddr);

  // 7. Wire contracts together
  await pool.setPositionManager(pmAddr);
  await pool.setRouter(routerAddr);
  await positionManager.setPool(poolAddr);
  await positionManager.setRouter(routerAddr);
  await positionManager.setFundingRate(frAddr);
  await fundingRate.setPositionManager(pmAddr);
  await router.setFundingRate(frAddr);
  console.log("Contracts wired together");

  console.log("\n--- Perpetuals Deployment Complete ---");
  console.log({
    QUSD: qusdAddr,
    PriceOracle: oracleAddr,
    LiquidityPool: poolAddr,
    PositionManager: pmAddr,
    FundingRate: frAddr,
    PerpRouter: routerAddr,
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
