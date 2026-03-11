import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying QFC Lending Protocol with account:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  // ─── 1. Deploy mock ERC-20 tokens (for testnet) ───────────────────
  // In production, use existing token addresses
  const Token = await ethers.getContractFactory("QFCToken");

  const qfc = await Token.deploy("QFC Token", "QFC", ethers.parseEther("1000000000"), ethers.parseEther("100000000"));
  await qfc.waitForDeployment();
  console.log("QFC Token deployed to:", await qfc.getAddress());

  const ttk = await Token.deploy("Test Token", "TTK", ethers.parseEther("1000000000"), ethers.parseEther("100000000"));
  await ttk.waitForDeployment();
  console.log("TTK Token deployed to:", await ttk.getAddress());

  const qdoge = await Token.deploy("QDoge Token", "QDOGE", ethers.parseEther("1000000000000"), ethers.parseEther("100000000000"));
  await qdoge.waitForDeployment();
  console.log("QDOGE Token deployed to:", await qdoge.getAddress());

  const qusd = await Token.deploy("QUSD Stablecoin", "QUSD", ethers.parseEther("1000000000"), ethers.parseEther("100000000"));
  await qusd.waitForDeployment();
  console.log("QUSD Token deployed to:", await qusd.getAddress());

  // ─── 2. Deploy InterestRateModel ──────────────────────────────────
  const InterestRateModel = await ethers.getContractFactory("InterestRateModel");
  const interestRateModel = await InterestRateModel.deploy(
    ethers.parseEther("0.02"),   // 2% base rate
    ethers.parseEther("0.225"),  // multiplier: reaches ~20% at 80% util
    ethers.parseEther("4.0"),    // jump multiplier: steep above kink
    ethers.parseEther("0.8")     // 80% kink
  );
  await interestRateModel.waitForDeployment();
  console.log("InterestRateModel deployed to:", await interestRateModel.getAddress());

  // ─── 3. Deploy PriceOracle ────────────────────────────────────────
  const PriceOracle = await ethers.getContractFactory("PriceOracle");
  const oracle = await PriceOracle.deploy();
  await oracle.waitForDeployment();
  console.log("PriceOracle deployed to:", await oracle.getAddress());

  // Set initial prices (USD with 18 decimals)
  await oracle.setPrices(
    [await qfc.getAddress(), await ttk.getAddress(), await qdoge.getAddress(), await qusd.getAddress()],
    [
      ethers.parseEther("10"),      // QFC = $10
      ethers.parseEther("5"),       // TTK = $5
      ethers.parseEther("0.001"),   // QDOGE = $0.001
      ethers.parseEther("1"),       // QUSD = $1
    ]
  );
  console.log("Oracle prices set");

  // ─── 4. Deploy LendingPool ────────────────────────────────────────
  const LendingPool = await ethers.getContractFactory("LendingPool");
  const lendingPool = await LendingPool.deploy(await oracle.getAddress());
  await lendingPool.waitForDeployment();
  const lendingPoolAddr = await lendingPool.getAddress();
  console.log("LendingPool deployed to:", lendingPoolAddr);

  // ─── 5. Deploy QTokens ───────────────────────────────────────────
  const QTokenFactory = await ethers.getContractFactory("QToken");

  const assets = [
    { token: qfc, name: "QFC Lending QFC", symbol: "qQFC", cf: ethers.parseEther("0.75") },
    { token: ttk, name: "QFC Lending TTK", symbol: "qTTK", cf: ethers.parseEther("0.6") },
    { token: qdoge, name: "QFC Lending QDOGE", symbol: "qQDOGE", cf: ethers.parseEther("0.5") },
    { token: qusd, name: "QFC Lending QUSD", symbol: "qQUSD", cf: ethers.parseEther("0.8") },
  ];

  for (const asset of assets) {
    const qToken = await QTokenFactory.deploy(
      asset.name,
      asset.symbol,
      await asset.token.getAddress(),
      await interestRateModel.getAddress(),
      lendingPoolAddr
    );
    await qToken.waitForDeployment();
    console.log(`${asset.symbol} deployed to:`, await qToken.getAddress());

    // List market in LendingPool
    await lendingPool.listMarket(
      await asset.token.getAddress(),
      await qToken.getAddress(),
      asset.cf
    );
    console.log(`${asset.symbol} market listed with CF ${ethers.formatEther(asset.cf)}`);
  }

  // ─── Summary ──────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════");
  console.log("  QFC Lending Protocol Deployment Complete");
  console.log("═══════════════════════════════════════════");
  console.log("Markets:", await lendingPool.marketCount(), "listed");
  console.log("InterestRateModel:", await interestRateModel.getAddress());
  console.log("PriceOracle:", await oracle.getAddress());
  console.log("LendingPool:", lendingPoolAddr);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
