# AGENTS

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

Exactly Protocol is a decentralized DeFi lending protocol with both variable and fixed interest rates. It uses a novel approach where fixed rates are determined by utilization rates of pools with different maturity dates, rather than maturity token prices.

## Build and Test Commands

```bash
# Install dependencies
pnpm install

# Run all linters (Solidity, TypeScript, ESLint)
pnpm lint

# Run all tests (Foundry + Hardhat)
pnpm test

# Run only Foundry tests
pnpm test:foundry

# Run only Hardhat tests
pnpm test:hardhat

# Run a single Foundry test file
forge test --match-path test/Market.t.sol

# Run a single Foundry test function
forge test --match-test testBorrowAtMaturity

# Run Hardhat tests with specific file
hardhat test --deploy-fixture test/hardhat/2_market.ts

# Compile contracts
pnpm compile

# Gas snapshot
pnpm snapshot

# Coverage
pnpm coverage
```

## Architecture

### Core Contracts

- **Market.sol** - ERC4626 vault handling deposits/borrows for both floating and fixed-rate pools. Each asset has its own Market. Uses `MarketExtension` via delegatecall for some functions (transfer, initialize).

- **Auditor.sol** - Risk management contract that tracks collateral positions and validates borrowing. Handles:
  - Account liquidity calculations (collateral vs debt with adjust factors)
  - Liquidation validation and incentive calculations
  - Market enablement and price feed configuration
  - Uses a bitmap (`accountMarkets`) to track which markets an account has entered

- **InterestRateModel.sol** - Calculates variable and fixed rates using a sigmoid-based curve with parameters like `naturalUtilization`, `growthSpeed`, `sigmoidSpeed`.

- **RewardsController.sol** - Distributes reward tokens to depositors/borrowers based on their market activity.

### Fixed Rate Pools

The protocol uses 4-week maturity intervals (`FixedLib.INTERVAL = 4 weeks`). `FixedLib.sol` manages fixed-rate pool operations:

- Pools have `supplied`, `borrowed`, and `unassignedEarnings`
- `floatingBackupBorrowed` tracks floating pool liquidity lent to fixed pools
- Maturities are packed into bitmaps for efficient storage

### Periphery Contracts

- **DebtManager.sol** - Leveraging/deleveraging via Balancer flash loans
- **Previewer.sol** - Read-only aggregation of market data
- **InstallmentsRouter.sol** - Fixed-rate installment payments
- **StakedEXA.sol** - EXA token staking
- **EscrowedEXA.sol** - Vested EXA rewards

### Verified Contracts

`contracts/verified/` contains KYC-gated variants (VerifiedMarket, VerifiedAuditor, Firewall) for compliant deployments.

## Key Patterns

- Contracts use OpenZeppelin upgradeable patterns with ERC1967 proxies
- WAD (1e18) math via solmate's `FixedPointMathLib`
- Treasury fees collected via `depositToTreasury()` minting shares
- Market state changes emit `MarketUpdate` events for indexing
- Pausing uses both `PAUSER_ROLE` and `EMERGENCY_ADMIN_ROLE`

## Configuration

`hardhat.config.ts` contains market parameters, IRM configurations, and reward distributions per network. The `finance` config object defines:

- `liquidationIncentive` - liquidator/lenders shares
- `marketDefaults` - default IRM params, fees, pool counts
- `markets` - per-asset overrides with network-specific rewards

## Testing

- **Foundry tests** (`test/*.t.sol`): Unit/fuzz/invariant tests. Use `Protocol.t.sol` for protocol-wide invariants.
- **Hardhat tests** (`test/hardhat/*.ts`): Integration tests using fixtures. Run with `--deploy-fixture`.
- Test helpers in `test/hardhat/marketEnv.ts` and `test/hardhat/defaultEnv.ts`

Foundry profiles:

- `default` - standard testing
- `snapshot` - for gas snapshots (`bytecode_hash = "none"`)
- `production` - extended fuzz runs (66,666 runs)
- `overkill` - maximum fuzz coverage (6,666,666 runs)

## Solidity Style

- Solidity ^0.8.17, compiled with 0.8.26, cancun EVM
- Max line length: 120 characters
- Errors defined at file level (not in contracts)
- Use `solhint-disable` annotations for expected warnings
