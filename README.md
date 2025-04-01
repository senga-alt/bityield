# BitYield Protocol - Smart Contract Documentation

## Overview

BitYield Protocol is an enterprise-grade DeFi aggregation protocol operating on Stacks L2, designed to automate cross-protocol yield optimization while maintaining Bitcoin-native security. This smart contract enables sophisticated yield strategies across multiple Stacks-based DeFi protocols with integrated risk management and gasless transaction capabilities.

## Key Features

1. **Multi-Protocol Yield Aggregation**

   - Automated fund allocation across registered DeFi protocols
   - Dynamic rebalancing based on market conditions
   - Support for multiple protocol types (Lending, DEX, Farming)

2. **Risk-Aware Architecture**

   - Protocol-specific liquidation thresholds
   - Real-time position health monitoring
   - User-configurable risk parameters

3. **Unified Management**

   - Cross-protocol portfolio tracking
   - Batch transaction processing
   - Consolidated yield reporting

4. **Bitcoin-Native Security**
   - STX-based settlements with Bitcoin finality
   - Protocol-level access controls
   - Secure fund allocation mechanisms

## Smart Contract Components

### Core Data Structures

#### Protocol Registry

```clarity
(define-map protocols
  { protocol-id: uint }
  {
    name: (string-ascii 64),
    protocol-address: principal,
    is-active: bool,
    trusted: bool,
    supported-tokens: (list 10 (string-ascii 32)),
    protocol-type: (string-ascii 32)
  }
)
```

#### Yield Vault Structure

```clarity
(define-map vaults
  { vault-id: uint }
  {
    creator: principal,
    name: (string-ascii 64),
    description: (string-ascii 256),
    strategy: (string-ascii 32),
    target-apy: uint,
    risk-level: uint,
    allocation: (list 10 {protocol-id: uint, percentage: uint}),
    is-active: bool,
    total-assets-ustx: uint,
    creation-height: uint
  }
)
```

### Error Codes

| Code | Constant                  | Description                        |
| ---- | ------------------------- | ---------------------------------- |
| 100  | ERR-NOT-AUTHORIZED        | Unauthorized access attempt        |
| 101  | ERR-INVALID-PROTOCOL      | Unregistered protocol interaction  |
| 102  | ERR-INSUFFICIENT-FUNDS    | Insufficient balance for operation |
| 104  | ERR-VAULT-NOT-FOUND       | Non-existent vault access          |
| 109  | ERR-LIQUIDATION-THRESHOLD | Position exceeds safety threshold  |
| 111  | ERR-SLIPPAGE-TOO-HIGH     | Transaction exceeds max slippage   |

## Core Functionality

### Protocol Management

**Register New Protocol**

```clarity
(define-public (register-protocol
                (name (string-ascii 64))
                (protocol-address principal)
                (supported-tokens (list 10 (string-ascii 32)))
                (protocol-type (string-ascii 32)))
```

**Set Risk Parameters**

```clarity
(define-public (set-protocol-risk-params
                (protocol-id uint)
                (liquidation-threshold uint)
                (max-ltv uint)
                (liquidation-penalty uint)
                (oracle-address principal))
```

### Vault Operations

**Create Yield Vault**

```clarity
(define-public (create-vault
                (name (string-ascii 64))
                (description (string-ascii 256))
                (strategy (string-ascii 32))
                (target-apy uint)
                (risk-level uint)
                (allocation (list 10 {protocol-id: uint, percentage: uint})))
```

**Deposit to Vault**

```clarity
(define-public (deposit-to-vault (vault-id uint) (amount-ustx uint))
```

**Withdraw from Vault**

```clarity
(define-public (withdraw-from-vault (vault-id uint) (amount-ustx uint))
```

### Risk Management

**User Risk Preferences**

```clarity
(define-public (set-risk-preferences
                (liquidation-alert-threshold uint)
                (rebalance-threshold uint)
                (max-slippage uint)
                (notification-enabled bool))
```

**Liquidation Check**

```clarity
(define-public (check-liquidation-risk (user principal) (protocol-id uint))
```

## Advanced Features

### Gasless Batch Transactions

```clarity
(define-public (execute-batch-transaction
                (actions (list 10 {protocol-id: uint, action: (string-ascii 32), params: (list 5 {key: (string-ascii 32), value: uint})})))
```

Example Batch Action:

```json
[
  {
    "protocol-id": 1,
    "action": "supply",
    "params": [
      { "key": "token", "value": "STX" },
      { "key": "amount", "value": 5000 }
    ]
  },
  {
    "protocol-id": 2,
    "action": "stake",
    "params": [
      { "key": "pool", "value": "STX-USD" },
      { "key": "duration", "value": 14400 }
    ]
  }
]
```

### Portfolio Tracking

```clarity
(define-read-only (get-portfolio-value (user principal))
```

## Security Model

1. **Access Control**

   - Contract owner management through `contract-owner` principal
   - Protocol trust levels and activation states
   - Vault creator permissions

2. **Fund Safety**

   - STX transfers using `as-contract` wrapper
   - Allocation percentage validation (total 100%)
   - Withdrawal amount verification

3. **Risk Mitigation**
   - Protocol-specific LTV ratios
   - Liquidation penalty parameters
   - Oracle-integrated price feeds

## Usage Examples

### Creating a Yield Vault

```clarity
(create-vault
  "BTC Yield Aggregator"
  "Balanced portfolio for BTC-related assets"
  "balanced-btc"
  u1500  ;; 15% target APY
  u5     ;; Medium risk level
  [
    {protocol-id: u1, percentage: u40},  ;; Lending protocol
    {protocol-id: u2, percentage: u30},  ;; DEX liquidity
    {protocol-id: u3, percentage: u30}   ;; Yield farming
  ]
)
```

### Executing Cross-Protocol Actions

```clarity
(execute-batch-transaction
  (list
    {
      protocol-id: u1,
      action: "supply-and-borrow",
      params: [
        {key: "supply-token", value: "STX"},
        {key: "supply-amount", value: u5000},
        {key: "borrow-token", value: "BTC"},
        {key: "borrow-ltv", value: u65}
      ]
    },
    {
      protocol-id: u2,
      action: "add-liquidity",
      params: [
        {key: "pool", value: "STX-BTC"},
        {key: "amountA", value: u2000},
        {key: "amountB", value: u50}
      ]
    }
  )
)
```

## Development Notes

1. **Mock Implementations**

   - Protocol interactions use placeholder functions
   - Actual implementation requires integration with:
     - Lending protocol adapters
     - DEX router contracts
     - Price oracle interfaces

2. **Testing Considerations**

   - Verify allocation percentages sum to 100%
   - Check protocol activation before interactions
   - Validate risk parameter boundaries
   - Test edge cases for large STX amounts

3. **Upgrade Path**
   - Contract owner can deactivate protocols
   - Vault creators can pause strategies
   - New protocol types can be added dynamically
