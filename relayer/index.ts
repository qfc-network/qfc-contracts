import express from "express";
import cors from "cors";
import { ethers } from "ethers";
import * as dotenv from "dotenv";

dotenv.config();

// ---------------------------------------------------------------------------
// ShieldedPool Relayer Service
//
// Accepts ZK proofs from users and submits withdrawal transactions on-chain,
// paying gas on behalf of users. Earns a configurable relayer fee.
//
// Endpoints:
//   GET  /status          — Health check + pool info
//   POST /relay           — Submit a withdrawal proof
//   GET  /jobs/:id        — Check relay job status
// ---------------------------------------------------------------------------

const PORT = parseInt(process.env.RELAYER_PORT || "3290");
const RPC_URL = process.env.RPC_URL || "http://localhost:8545";
const PRIVATE_KEY = process.env.RELAYER_PRIVATE_KEY || "";
const POOL_ADDRESS = process.env.SHIELDED_POOL_ADDRESS || "";

if (!PRIVATE_KEY) {
  console.error("❌ RELAYER_PRIVATE_KEY not set");
  process.exit(1);
}
if (!POOL_ADDRESS) {
  console.error("❌ SHIELDED_POOL_ADDRESS not set");
  process.exit(1);
}

// --- ABI (ShieldedPoolV2 withdraw function) ---
const POOL_ABI = [
  "function withdraw(uint[2] _pA, uint[2][2] _pB, uint[2] _pC, uint256 _root, uint256 _nullifierHash, address _recipient, address _relayer, uint256 _denomination) external",
  "function nullifierUsed(uint256) view returns (bool)",
  "function isKnownRoot(uint256) view returns (bool)",
  "function relayerFeeBps() view returns (uint256)",
  "function supportedDenominations(uint256) view returns (bool)",
  "function getPoolBalance() view returns (uint256)",
  "function depositCount() view returns (uint256)",
];

// --- State ---
interface RelayJob {
  id: string;
  status: "pending" | "submitted" | "confirmed" | "failed";
  txHash?: string;
  error?: string;
  timestamp: number;
}

const jobs: Map<string, RelayJob> = new Map();
let jobCounter = 0;

// --- Setup ---
const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
const pool = new ethers.Contract(POOL_ADDRESS, POOL_ABI, wallet);

const app = express();
app.use(cors());
app.use(express.json());

// ---------------------------------------------------------------------------
// GET /status
// ---------------------------------------------------------------------------
app.get("/status", async (_req, res) => {
  try {
    const [balance, feeBps, poolBalance, deposits, relayerBal] = await Promise.all([
      provider.getBalance(wallet.address),
      pool.relayerFeeBps(),
      pool.getPoolBalance(),
      pool.depositCount(),
      provider.getBalance(wallet.address),
    ]);

    res.json({
      status: "ok",
      relayer: wallet.address,
      gasBalance: ethers.formatEther(balance),
      poolAddress: POOL_ADDRESS,
      poolBalance: ethers.formatEther(poolBalance),
      totalDeposits: deposits.toString(),
      relayerFeeBps: feeBps.toString(),
      pendingJobs: [...jobs.values()].filter(j => j.status === "pending").length,
    });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// POST /relay
// ---------------------------------------------------------------------------
interface RelayRequest {
  proof: {
    pA: [string, string];
    pB: [[string, string], [string, string]];
    pC: [string, string];
  };
  root: string;
  nullifierHash: string;
  recipient: string;
  denomination: string;
}

app.post("/relay", async (req, res) => {
  try {
    const body: RelayRequest = req.body;

    // Validate inputs
    if (!body.proof || !body.root || !body.nullifierHash || !body.recipient || !body.denomination) {
      return res.status(400).json({ error: "Missing required fields" });
    }

    if (!ethers.isAddress(body.recipient)) {
      return res.status(400).json({ error: "Invalid recipient address" });
    }

    // Check nullifier hasn't been used
    const used = await pool.nullifierUsed(BigInt(body.nullifierHash));
    if (used) {
      return res.status(400).json({ error: "Nullifier already used (double-spend attempt)" });
    }

    // Check root is known
    const validRoot = await pool.isKnownRoot(BigInt(body.root));
    if (!validRoot) {
      return res.status(400).json({ error: "Unknown Merkle root" });
    }

    // Check denomination is supported
    const validDenom = await pool.supportedDenominations(BigInt(body.denomination));
    if (!validDenom) {
      return res.status(400).json({ error: "Unsupported denomination" });
    }

    // Create job
    jobCounter++;
    const jobId = `relay-${jobCounter}-${Date.now()}`;
    const job: RelayJob = {
      id: jobId,
      status: "pending",
      timestamp: Date.now(),
    };
    jobs.set(jobId, job);

    // Submit transaction (async, don't await)
    submitWithdrawal(job, body).catch(err => {
      console.error(`Job ${jobId} failed:`, err.message);
    });

    res.json({
      jobId,
      status: "pending",
      message: "Withdrawal proof accepted, submitting transaction...",
    });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

async function submitWithdrawal(job: RelayJob, body: RelayRequest) {
  try {
    const { proof, root, nullifierHash, recipient, denomination } = body;

    const tx = await pool.withdraw(
      proof.pA.map(BigInt),
      proof.pB.map((row: string[]) => row.map(BigInt)),
      proof.pC.map(BigInt),
      BigInt(root),
      BigInt(nullifierHash),
      recipient,
      wallet.address, // relayer = us (we get the fee)
      BigInt(denomination),
    );

    job.status = "submitted";
    job.txHash = tx.hash;
    console.log(`Job ${job.id}: tx submitted ${tx.hash}`);

    const receipt = await tx.wait();
    if (receipt && receipt.status === 1) {
      job.status = "confirmed";
      console.log(`Job ${job.id}: confirmed in block ${receipt.blockNumber}`);
    } else {
      job.status = "failed";
      job.error = "Transaction reverted";
    }
  } catch (err: any) {
    job.status = "failed";
    job.error = err.message;
    console.error(`Job ${job.id}: failed — ${err.message}`);
  }
}

// ---------------------------------------------------------------------------
// GET /jobs/:id
// ---------------------------------------------------------------------------
app.get("/jobs/:id", (req, res) => {
  const job = jobs.get(req.params.id);
  if (!job) {
    return res.status(404).json({ error: "Job not found" });
  }
  res.json(job);
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
app.listen(PORT, () => {
  console.log(`\n🛡️  ShieldedPool Relayer`);
  console.log(`   Address:  ${wallet.address}`);
  console.log(`   Pool:     ${POOL_ADDRESS}`);
  console.log(`   RPC:      ${RPC_URL}`);
  console.log(`   Port:     ${PORT}`);
  console.log(`   Ready to relay withdrawals\n`);
});
