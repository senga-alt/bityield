;; BitYield Protocol: Cross-Protocol Yield Optimizer with Risk-Aware Management on Stacks L2
;; 
;; Summary: Enterprise-grade DeFi aggregation protocol enabling automated yield strategies across multiple
;; Stacks-based DeFi protocols with integrated risk management and Bitcoin settlement finality.

;; Description:
;; The BitYield Protocol revolutionizes decentralized yield optimization by combining:
;; - Multi-protocol strategy vaults with automatic rebalancing
;; - Real-time risk monitoring with liquidation protection
;; - Unified portfolio tracking across Stacks DeFi ecosystem
;; - Gasless batch transactions with Bitcoin-native security

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-PROTOCOL (err u101))
(define-constant ERR-INSUFFICIENT-FUNDS (err u102))
(define-constant ERR-INVALID-AMOUNT (err u103))
(define-constant ERR-VAULT-NOT-FOUND (err u104))
(define-constant ERR-PROTOCOL-NOT-REGISTERED (err u105))
(define-constant ERR-UNAUTHORIZED-PROTOCOL (err u106))
(define-constant ERR-INVALID-PARAMETER (err u107))
(define-constant ERR-POSITION-NOT-FOUND (err u108))
(define-constant ERR-LIQUIDATION-THRESHOLD (err u109))
(define-constant ERR-VAULT-FULL (err u110))
(define-constant ERR-SLIPPAGE-TOO-HIGH (err u111))
(define-constant ERR-UNSUPPORTED-TOKEN (err u112))

;; Data maps and variables

;; Track the contract owner
(define-data-var contract-owner principal tx-sender)

;; Protocol registry
(define-map protocols
  { protocol-id: uint }
  {
    name: (string-ascii 64),
    protocol-address: principal,
    is-active: bool,
    trusted: bool,
    supported-tokens: (list 10 (string-ascii 32)),
    protocol-type: (string-ascii 32) ;; lending, dex, farm, etc.
  }
)

;; Vault data structure
(define-map vaults
  { vault-id: uint }
  {
    creator: principal,
    name: (string-ascii 64),
    description: (string-ascii 256),
    strategy: (string-ascii 32),
    target-apy: uint,
    risk-level: uint, ;; 1-10, where 10 is highest risk
    allocation: (list 10 {protocol-id: uint, percentage: uint}),
    is-active: bool,
    total-assets-ustx: uint,
    creation-height: uint
  }
)

;; User positions in vaults
(define-map user-vault-positions
  { user: principal, vault-id: uint }
  {
    amount-ustx: uint,
    entry-height: uint,
    last-rebalance-height: uint,
    earnings-ustx: uint,
    strategy-params: (optional (tuple (key (string-ascii 32)) (value uint)))
  }
)

;; User positions across protocols (portfolio tracker)
(define-map user-protocol-positions
  { user: principal, protocol-id: uint }
  {
    supplied-assets: (list 5 {token: (string-ascii 32), amount: uint}),
    borrowed-assets: (list 5 {token: (string-ascii 32), amount: uint}),
    liquidity-positions: (list 5 {pool-id: (string-ascii 32), amount: uint}),
    staked-positions: (list 5 {asset: (string-ascii 32), amount: uint}),
    last-updated-height: uint
  }
)

;; Risk parameters for lending protocols
(define-map protocol-risk-params
  { protocol-id: uint }
  {
    liquidation-threshold: uint, ;; percentage (e.g., 75 = 75%)
    max-ltv: uint,             ;; percentage
    liquidation-penalty: uint,  ;; percentage
    oracle-address: principal
  }
)

;; User risk alert settings
(define-map user-risk-settings
  { user: principal }
  {
    liquidation-alert-threshold: uint, ;; percentage buffer above liquidation (e.g., 5 = 5%)
    rebalance-threshold: uint,        ;; percentage deviation from target allocation
    max-slippage: uint,               ;; percentage
    notification-enabled: bool
  }
)

;; Counters for IDs
(define-data-var next-protocol-id uint u1)
(define-data-var next-vault-id uint u1)

;; Events
(define-trait event-trait
  (
    (emit-event (string-ascii 64) (string-ascii 256) ) (response bool uint)
  )
)

;; Admin functions

;; Initialize contract with the contract owner
(define-public (initialize (owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-owner owner)
    (ok true)
  )
)

;; Add a new protocol to the registry
(define-public (register-protocol 
                (name (string-ascii 64)) 
                (protocol-address principal) 
                (supported-tokens (list 10 (string-ascii 32))) 
                (protocol-type (string-ascii 32)))
  (let
    (
      (protocol-id (var-get next-protocol-id))
    )
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (map-set protocols
      { protocol-id: protocol-id }
      {
        name: name,
        protocol-address: protocol-address,
        is-active: true,
        trusted: true,
        supported-tokens: supported-tokens,
        protocol-type: protocol-type
      }
    )
    (var-set next-protocol-id (+ protocol-id u1))
    (ok protocol-id)
  )
)

;; Update protocol status (activate/deactivate)
(define-public (update-protocol-status (protocol-id uint) (is-active bool) (trusted bool))
  (let
    (
      (protocol (unwrap! (map-get? protocols { protocol-id: protocol-id }) ERR-PROTOCOL-NOT-REGISTERED))
    )
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (map-set protocols
      { protocol-id: protocol-id }
      (merge protocol { is-active: is-active, trusted: trusted })
    )
    (ok true)
  )
)

;; Set risk parameters for a lending protocol
(define-public (set-protocol-risk-params
                (protocol-id uint)
                (liquidation-threshold uint)
                (max-ltv uint)
                (liquidation-penalty uint)
                (oracle-address principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (is-some (map-get? protocols { protocol-id: protocol-id })) ERR-PROTOCOL-NOT-REGISTERED)
    (asserts! (<= liquidation-threshold u100) ERR-INVALID-PARAMETER)
    (asserts! (<= max-ltv liquidation-threshold) ERR-INVALID-PARAMETER)
    (asserts! (<= liquidation-penalty u100) ERR-INVALID-PARAMETER)
    
    (map-set protocol-risk-params
      { protocol-id: protocol-id }
      {
        liquidation-threshold: liquidation-threshold,
        max-ltv: max-ltv,
        liquidation-penalty: liquidation-penalty,
        oracle-address: oracle-address
      }
    )
    (ok true)
  )
)

;; Vault functions

;; Create a new yield optimization vault
(define-public (create-vault
                (name (string-ascii 64))
                (description (string-ascii 256))
                (strategy (string-ascii 32))
                (target-apy uint)
                (risk-level uint)
                (allocation (list 10 {protocol-id: uint, percentage: uint})))
  (let
    (
      (vault-id (var-get next-vault-id))
      (total-percentage (fold + (map get-percentage allocation) u0))
    )
    ;; Validate input parameters
    (asserts! (and (>= risk-level u1) (<= risk-level u10)) ERR-INVALID-PARAMETER)
    (asserts! (is-eq total-percentage u100) ERR-INVALID-PARAMETER)
    
    ;; Check all protocols in allocation exist and are active
    (asserts! (validate-allocation allocation) ERR-INVALID-PROTOCOL)
    
    ;; Create the vault
    (map-set vaults
      { vault-id: vault-id }
      {
        creator: tx-sender,
        name: name,
        description: description,
        strategy: strategy,
        target-apy: target-apy,
        risk-level: risk-level,
        allocation: allocation,
        is-active: true,
        total-assets-ustx: u0,
        creation-height: block-height
      }
    )
    (var-set next-vault-id (+ vault-id u1))
    (ok vault-id)
  )
)

;; Helper function to extract percentage from allocation entry
(define-private (get-percentage (entry {protocol-id: uint, percentage: uint}))
  (get percentage entry)
)

;; Validate that all protocols in allocation exist and are active
(define-private (validate-allocation (allocation (list 10 {protocol-id: uint, percentage: uint})))
  (fold and (map validate-protocol-in-allocation allocation) true)
)

;; Validate a single protocol in allocation
(define-private (validate-protocol-in-allocation (entry {protocol-id: uint, percentage: uint}))
  (match (map-get? protocols { protocol-id: (get protocol-id entry) })
    protocol (get is-active protocol)
    false
  )
)

;; Deposit assets into a vault
(define-public (deposit-to-vault (vault-id uint) (amount-ustx uint))
  (let
    (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
      (user-position (default-to 
                       {
                         amount-ustx: u0,
                         entry-height: block-height,
                         last-rebalance-height: block-height,
                         earnings-ustx: u0,
                         strategy-params: none
                       }
                       (map-get? user-vault-positions { user: tx-sender, vault-id: vault-id })))
    )
    ;; Validate
    (asserts! (get is-active vault) ERR-VAULT-NOT-FOUND)
    (asserts! (> amount-ustx u0) ERR-INVALID-AMOUNT)
    
    ;; Transfer STX to contract
    (try! (stx-transfer? amount-ustx tx-sender (as-contract tx-sender)))
    
    ;; Update user position
    (map-set user-vault-positions
      { user: tx-sender, vault-id: vault-id }
      (merge user-position { 
        amount-ustx: (+ (get amount-ustx user-position) amount-ustx),
        last-rebalance-height: block-height
      })
    )
    
    ;; Update vault total assets
    (map-set vaults
      { vault-id: vault-id }
      (merge vault { 
        total-assets-ustx: (+ (get total-assets-ustx vault) amount-ustx) 
      })
    )
    
    ;; Allocate funds according to vault strategy
    (try! (allocate-funds vault-id tx-sender amount-ustx))
    
    (ok true)
  )
)