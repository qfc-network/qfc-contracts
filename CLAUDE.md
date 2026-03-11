# CLAUDE.md - QFC Contracts

## Project Overview

QFC smart contract example library built with Hardhat and Solidity. Provides production-ready templates for tokens, staking, governance, and DeFi applications.

## Tech Stack

- **Solidity** ^0.8.24 (Cancun EVM) - Smart contract language
- **Hardhat** - Development framework
- **OpenZeppelin** - Security-audited contract libraries
- **TypeScript** - Scripts and tests
- **Chai/Mocha** - Testing framework

## Build Commands

```bash
# Install dependencies
npm install

# Compile contracts
npm run compile
# or: npx hardhat compile

# Run all tests
npm test
# or: npx hardhat test

# Run single test file
npx hardhat test test/QFCToken.test.ts

# Run tests with gas reporting
REPORT_GAS=true npm test

# Generate coverage report
npm run coverage

# Deploy locally
npm run deploy

# Deploy to testnet
npm run deploy:testnet
```

## Project Structure

```
contracts/
├── tokens/           # ERC-20, ERC-721, ERC-1155
├── staking/          # Staking pools, reward distribution
├── governance/       # Governor, Treasury
├── defi/             # AMM, Vault
└── utils/            # Multicall, Create2Factory

scripts/              # Deployment scripts
test/                 # Test files
```

## Key Contracts

### Tokens
- `QFCToken.sol` - ERC-20 with mint cap, permit, batch transfers
- `QFCNFT.sol` - ERC-721 with enumerable, mint price
- `QFCMultiToken.sol` - ERC-1155 with supply tracking

### Staking
- `StakingPool.sol` - Time-weighted rewards, lock period
- `RewardDistributor.sol` - Merkle-proof based claims

### Governance
- `QFCGovernor.sol` - OpenZeppelin Governor with timelock
- `Treasury.sol` - Role-based DAO treasury

### DeFi
- `SimpleSwap.sol` - Constant product AMM (x*y=k), 0.3% fee
- `Vault.sol` - ERC4626-like yield vault

### Utils
- `Multicall.sol` - Batch contract calls
- `Create2Factory.sol` - Deterministic deployment

## Code Style

- Solidity follows OpenZeppelin patterns
- NatSpec comments on all public functions
- Events emitted for state changes
- Access control via Ownable or AccessControl
- SafeERC20 for token transfers

## Testing

Tests use Hardhat network with fixtures:

```typescript
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

async function deployFixture() {
  const [owner, user] = await ethers.getSigners();
  const Token = await ethers.getContractFactory("QFCToken");
  const token = await Token.deploy(...);
  return { token, owner, user };
}

it("should work", async function() {
  const { token } = await loadFixture(deployFixture);
  // test...
});
```

## Network Configuration

Networks defined in `hardhat.config.ts`:
- `localhost` - Local Hardhat node (chainId: 31337)
- `testnet` - QFC Testnet (chainId: 9000)
- `mainnet` - QFC Mainnet (chainId: 9001)

## Environment Variables

Copy `.env.example` to `.env`:
- `PRIVATE_KEY` - Deployer private key
- `QFC_TESTNET_RPC` - Testnet RPC URL
- `QFC_MAINNET_RPC` - Mainnet RPC URL
- `EXPLORER_API_KEY` - For contract verification

## Common Patterns

### Deploy Contract
```typescript
const Contract = await ethers.getContractFactory("ContractName");
const contract = await Contract.deploy(arg1, arg2);
await contract.waitForDeployment();
console.log("Address:", await contract.getAddress());
```

### Interact with Contract
```typescript
const contract = await ethers.getContractAt("ContractName", address);
await contract.someFunction(args);
```

### Test Events
```typescript
await expect(contract.someFunction())
  .to.emit(contract, "EventName")
  .withArgs(arg1, arg2);
```

### Test Reverts
```typescript
await expect(contract.someFunction())
  .to.be.revertedWith("Error message");

await expect(contract.someFunction())
  .to.be.revertedWithCustomError(contract, "ErrorName");
```
