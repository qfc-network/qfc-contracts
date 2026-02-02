# QFC Smart Contracts

A comprehensive library of smart contract examples and templates for the QFC blockchain.

## Overview

This repository provides production-ready smart contract templates covering:

- **Tokens** - ERC-20, ERC-721, ERC-1155 implementations
- **Staking** - Staking pools with time-weighted rewards
- **Governance** - DAO governance with OpenZeppelin Governor
- **DeFi** - AMM swap and yield vault contracts
- **Utilities** - Multicall, CREATE2 factory, and more

## Installation

```bash
npm install
```

## Quick Start

### Compile Contracts

```bash
npm run compile
```

### Run Tests

```bash
npm test
```

### Deploy to Local Network

```bash
npx hardhat node
npm run deploy
```

### Deploy to Testnet

```bash
# Copy and configure environment
cp .env.example .env
# Edit .env with your private key

npm run deploy:testnet
```

## Contracts

### Tokens

#### QFCToken (ERC-20)
Full-featured ERC-20 token with:
- Minting with cap limit
- Burning
- Permit (gasless approvals)
- Batch transfers
- Owner-controlled minting

```solidity
import "./tokens/QFCToken.sol";

QFCToken token = new QFCToken(
    "My Token",
    "MTK",
    1000000 ether,  // cap
    100000 ether    // initial supply
);
```

#### QFCNFT (ERC-721)
NFT collection with:
- Enumerable extension
- URI storage
- Mint price mechanism
- Owner-controlled minting
- Max supply limit

```solidity
import "./tokens/QFCNFT.sol";

QFCNFT nft = new QFCNFT(
    "My NFT",
    "MNFT",
    "https://api.example.com/metadata/",
    10000,          // max supply
    0.1 ether       // mint price
);
```

#### QFCMultiToken (ERC-1155)
Multi-token with:
- Supply tracking per token ID
- Batch minting
- URI management
- Owner controls

### Staking

#### StakingPool
Time-weighted staking rewards with:
- Configurable reward rate
- Lock period enforcement
- Emergency withdrawal
- Reward updates per block

```solidity
import "./staking/StakingPool.sol";

StakingPool pool = new StakingPool(
    stakingTokenAddress,
    rewardTokenAddress,
    rewardPerSecond,
    lockPeriod
);
```

#### RewardDistributor
Merkle-tree based reward distribution:
- Epoch-based claims
- Merkle proof verification
- Multiple distribution rounds

### Governance

#### QFCGovernor
OpenZeppelin Governor implementation:
- Token-based voting
- Timelock execution
- Configurable voting parameters
- Proposal lifecycle management

#### Treasury
DAO treasury management:
- Role-based access control
- ETH and token withdrawals
- Spending limits
- Proposer/executor roles

### DeFi

#### SimpleSwap
Constant product AMM (x * y = k):
- Add/remove liquidity
- Swap token0 for token1 and vice versa
- 0.3% swap fee
- Price oracles

```solidity
import "./defi/SimpleSwap.sol";

SimpleSwap swap = new SimpleSwap(token0Address, token1Address);

// Add liquidity
swap.addLiquidity(amount0, amount1);

// Swap
swap.swap0For1(amountIn, minAmountOut);
```

#### Vault
ERC4626-like yield vault:
- Deposit/withdraw underlying tokens
- Share-based accounting
- Management fee
- Harvest mechanism

### Utilities

#### Multicall
Batch multiple contract calls:
- Aggregate calls in single transaction
- Optional failure tolerance
- Gas efficient

#### Create2Factory
Deterministic contract deployment:
- Predictable addresses
- Salt-based deployment
- Compute address before deployment

## Project Structure

```
qfc-contracts/
├── contracts/
│   ├── tokens/
│   │   ├── QFCToken.sol      # ERC-20 token
│   │   ├── QFCNFT.sol        # ERC-721 NFT
│   │   └── QFCMultiToken.sol # ERC-1155 multi-token
│   ├── staking/
│   │   ├── StakingPool.sol       # Staking with rewards
│   │   └── RewardDistributor.sol # Merkle distribution
│   ├── governance/
│   │   ├── QFCGovernor.sol   # DAO governance
│   │   └── Treasury.sol      # DAO treasury
│   ├── defi/
│   │   ├── SimpleSwap.sol    # AMM DEX
│   │   └── Vault.sol         # Yield vault
│   └── utils/
│       ├── Multicall.sol     # Batch calls
│       └── Create2Factory.sol # Deterministic deploy
├── scripts/
│   ├── deploy.ts             # Token deployment
│   ├── deploy-staking.ts     # Staking deployment
│   └── deploy-defi.ts        # DeFi deployment
├── test/
│   ├── QFCToken.test.ts      # Token tests
│   └── SimpleSwap.test.ts    # Swap tests
├── hardhat.config.ts
└── package.json
```

## Networks

| Network | Chain ID | RPC URL |
|---------|----------|---------|
| Localhost | 31337 | http://127.0.0.1:8545 |
| QFC Testnet | 9000 | https://rpc.testnet.qfc.network |
| QFC Mainnet | 9001 | https://rpc.qfc.network |

## Scripts

```bash
# Compile contracts
npm run compile

# Run tests
npm test

# Run tests with coverage
npm run coverage

# Deploy to local network
npm run deploy

# Deploy to testnet
npm run deploy:testnet

# Deploy staking contracts
npm run deploy:staking

# Deploy DeFi contracts
npm run deploy:defi

# Verify contract on explorer
npx hardhat verify --network testnet <contract-address> <constructor-args>
```

## Security Considerations

These contracts are provided as examples and templates. Before using in production:

1. **Audit** - Get professional security audits
2. **Test** - Write comprehensive tests for your use case
3. **Review** - Carefully review all parameters and configurations
4. **Timelock** - Use timelocks for privileged operations
5. **Access Control** - Properly configure admin roles

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) - Security-audited implementations
- [Hardhat](https://hardhat.org/) - Development environment
- [ethers.js](https://docs.ethers.org/) - Ethereum library

## License

MIT License - see [LICENSE](LICENSE) for details.
