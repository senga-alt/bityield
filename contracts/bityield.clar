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

;; Withdraw assets from a vault
(define-public (withdraw-from-vault (vault-id uint) (amount-ustx uint))
  (let
    (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
      (user-position (unwrap! (map-get? user-vault-positions { user: tx-sender, vault-id: vault-id }) ERR-POSITION-NOT-FOUND))
    )
    ;; Validate
    (asserts! (get is-active vault) ERR-VAULT-NOT-FOUND)
    (asserts! (>= (get amount-ustx user-position) amount-ustx) ERR-INSUFFICIENT-FUNDS)
    
    ;; Withdraw from protocols according to allocation
    (try! (deallocate-funds vault-id tx-sender amount-ustx))
    
    ;; Update user position
    (map-set user-vault-positions
      { user: tx-sender, vault-id: vault-id }
      (merge user-position { 
        amount-ustx: (- (get amount-ustx user-position) amount-ustx)
      })
    )
    
    ;; Update vault total assets
    (map-set vaults
      { vault-id: vault-id }
      (merge vault { 
        total-assets-ustx: (- (get total-assets-ustx vault) amount-ustx) 
      })
    )
    
    ;; Transfer STX to user
    (as-contract (stx-transfer? amount-ustx tx-sender tx-sender))
    
    (ok true)
  )
)

;; Allocate funds according to vault strategy
(define-private (allocate-funds (vault-id uint) (user principal) (amount-ustx uint))
  (let
    (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
      (allocation (get allocation vault))
    )
    ;; Distribute funds according to allocation percentages
    (ok (distribute-to-protocols user allocation amount-ustx))
  )
)

;; Distribute funds to protocols according to allocation
(define-private (distribute-to-protocols (user principal) (allocation (list 10 {protocol-id: uint, percentage: uint})) (total-amount-ustx uint))
  (fold distribute-entry allocation total-amount-ustx)
)

;; Distribute a single allocation entry
(define-private (distribute-entry (entry {protocol-id: uint, percentage: uint}) (total-amount-ustx uint))
  (let
    (
      (protocol-id (get protocol-id entry))
      (percentage (get percentage entry))
      (amount-to-allocate (/ (* total-amount-ustx percentage) u100))
    )
    ;; Call the appropriate protocol adapter function
    ;; This is a simplified implementation - actual implementation would
    ;; call protocol-specific adapter contracts
    (mock-protocol-deposit protocol-id amount-to-allocate)
    total-amount-ustx
  )
)

;; Mock function for protocol deposit (would be replaced with actual protocol calls)
(define-private (mock-protocol-deposit (protocol-id uint) (amount-ustx uint))
  (print {action: "deposit", protocol-id: protocol-id, amount: amount-ustx})
  true
)

;; Deallocate funds from protocols (for withdrawal)
(define-private (deallocate-funds (vault-id uint) (user principal) (amount-ustx uint))
  (let
    (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
      (allocation (get allocation vault))
    )
    ;; Withdraw from protocols according to allocation percentages
    (ok (withdraw-from-protocols user allocation amount-ustx))
  )
)

;; Withdraw funds from protocols according to allocation
(define-private (withdraw-from-protocols (user principal) (allocation (list 10 {protocol-id: uint, percentage: uint})) (total-amount-ustx uint))
  (fold withdraw-entry allocation total-amount-ustx)
)

;; Withdraw a single allocation entry
(define-private (withdraw-entry (entry {protocol-id: uint, percentage: uint}) (total-amount-ustx uint))
  (let
    (
      (protocol-id (get protocol-id entry))
      (percentage (get percentage entry))
      (amount-to-withdraw (/ (* total-amount-ustx percentage) u100))
    )
    ;; Call the appropriate protocol adapter function
    (mock-protocol-withdraw protocol-id amount-to-withdraw)
    total-amount-ustx
  )
)

;; Mock function for protocol withdrawal (would be replaced with actual protocol calls)
(define-private (mock-protocol-withdraw (protocol-id uint) (amount-ustx uint))
  (print {action: "withdraw", protocol-id: protocol-id, amount: amount-ustx})
  true
)

;; Risk Management Functions

;; Set user risk preferences
(define-public (set-risk-preferences 
                (liquidation-alert-threshold uint) 
                (rebalance-threshold uint) 
                (max-slippage uint)
                (notification-enabled bool))
  (begin
    (asserts! (<= liquidation-alert-threshold u50) ERR-INVALID-PARAMETER)
    (asserts! (<= rebalance-threshold u50) ERR-INVALID-PARAMETER)
    (asserts! (<= max-slippage u50) ERR-INVALID-PARAMETER)
    
    (map-set user-risk-settings
      { user: tx-sender }
      {
        liquidation-alert-threshold: liquidation-alert-threshold,
        rebalance-threshold: rebalance-threshold,
        max-slippage: max-slippage,
        notification-enabled: notification-enabled
      }
    )
    (ok true)
  )
)

;; Check if a user's position needs liquidation alert
(define-public (check-liquidation-risk (user principal) (protocol-id uint))
  (let
    (
      (protocol (unwrap! (map-get? protocols { protocol-id: protocol-id }) ERR-PROTOCOL-NOT-REGISTERED))
      (risk-params (unwrap! (map-get? protocol-risk-params { protocol-id: protocol-id }) ERR-PROTOCOL-NOT-REGISTERED))
      (user-settings (default-to 
                      {
                        liquidation-alert-threshold: u5,
                        rebalance-threshold: u10,
                        max-slippage: u5,
                        notification-enabled: true
                      }
                      (map-get? user-risk-settings { user: user })))
      ;; This would be calculated based on actual position data from the protocol
      (current-ltv (mock-get-current-ltv user protocol-id))
      (liquidation-threshold (get liquidation-threshold risk-params))
      (alert-threshold (- liquidation-threshold (get liquidation-alert-threshold user-settings)))
    )
    (if (>= current-ltv alert-threshold)
      (begin
        (print {event: "liquidation-alert", user: user, protocol-id: protocol-id, current-ltv: current-ltv, threshold: alert-threshold})
        (ok true)
      )
      (ok false)
    )
  )
)

;; Mock function to get current LTV for a user (would be replaced with actual protocol calls)
(define-private (mock-get-current-ltv (user principal) (protocol-id uint))
  ;; For demonstration, return a fixed value
  u70 ;; 70% LTV
)

;; Rebalance a vault based on market conditions
(define-public (rebalance-vault (vault-id uint))
  (let
    (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
    )
    (asserts! (or 
                (is-eq tx-sender (get creator vault))
                (is-eq tx-sender (var-get contract-owner))
               ) 
              ERR-NOT-AUTHORIZED)
    
    ;; Perform the rebalancing logic
    ;; This would involve withdrawing from underperforming protocols and depositing into better ones
    (print {event: "rebalance-vault", vault-id: vault-id})
    
    (ok true)
  )
)

;; Portfolio Tracking Functions

;; Update a user's position in a protocol
(define-public (update-protocol-position
                (protocol-id uint)
                (supplied-assets (list 5 {token: (string-ascii 32), amount: uint}))
                (borrowed-assets (list 5 {token: (string-ascii 32), amount: uint}))
                (liquidity-positions (list 5 {pool-id: (string-ascii 32), amount: uint}))
                (staked-positions (list 5 {asset: (string-ascii 32), amount: uint})))
  (let
    (
      (protocol (unwrap! (map-get? protocols { protocol-id: protocol-id }) ERR-PROTOCOL-NOT-REGISTERED))
      (current-position (default-to 
                        {
                          supplied-assets: (list ),
                          borrowed-assets: (list ),
                          liquidity-positions: (list ),
                          staked-positions: (list ),
                          last-updated-height: u0
                        }
                        (map-get? user-protocol-positions { user: tx-sender, protocol-id: protocol-id })))
    )
    (asserts! (get is-active protocol) ERR-INVALID-PROTOCOL)
    
    (map-set user-protocol-positions
      { user: tx-sender, protocol-id: protocol-id }
      {
        supplied-assets: supplied-assets,
        borrowed-assets: borrowed-assets,
        liquidity-positions: liquidity-positions,
        staked-positions: staked-positions,
        last-updated-height: block-height
      }
    )
    
    (ok true)
  )
)

;; Get a user's total portfolio value (simplified version)
(define-read-only (get-portfolio-value (user principal))
  (let
    (
      (protocol-count (var-get next-protocol-id))
      (vault-count (var-get next-vault-id))
    )
    ;; Sum up the value across all protocols and vaults
    ;; This is a simplified implementation - actual would calculate real-time values
    (ok u0) ;; Placeholder return value
  )
)

;; Gasless Transaction Functions

;; Execute a batch transaction across multiple protocols
(define-public (execute-batch-transaction
                (actions (list 10 {protocol-id: uint, action: (string-ascii 32), params: (list 5 {key: (string-ascii 32), value: uint})})))
  (let
    (
      (action-count (len actions))
    )
    ;; Validate all actions
    (asserts! (> action-count u0) ERR-INVALID-PARAMETER)
    
    ;; Execute all actions in sequence
    (ok (execute-actions actions))
  )
)

;; Execute a list of actions
(define-private (execute-actions (actions (list 10 {protocol-id: uint, action: (string-ascii 32), params: (list 5 {key: (string-ascii 32), value: uint})})))
  (fold execute-single-action actions true)
)

;; Execute a single action within the batch
(define-private (execute-single-action 
                (action {protocol-id: uint, action: (string-ascii 32), params: (list 5 {key: (string-ascii 32), value: uint})})
                (previous-result bool))
  (let
    (
      (protocol-id (get protocol-id action))
      (action-type (get action action))
      (params (get params action))
    )
    ;; Call appropriate protocol action
    ;; This is a simplified implementation - would actually call protocol adapter contracts
    (print {execute: action-type, protocol: protocol-id, params: params})
    true
  )
)

;; Utility Functions

;; Calculate APY for a vault (simplified version)
(define-read-only (calculate-vault-apy (vault-id uint))
  (let
    (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
    )
    ;; This is a simplified implementation - would calculate based on actual returns
    (ok (get target-apy vault))
  )
)

;; Get all active vaults
(define-read-only (get-active-vaults)
  (ok u0) ;; Placeholder - would return list of active vault IDs
)

;; Get vault details
(define-read-only (get-vault-details (vault-id uint))
  (ok (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
)

;; Get protocol details
(define-read-only (get-protocol-details (protocol-id uint))
  (ok (unwrap! (map-get? protocols { protocol-id: protocol-id }) ERR-PROTOCOL-NOT-REGISTERED))
)

;; Get user position in vault
(define-read-only (get-user-vault-position (user principal) (vault-id uint))
  (ok (unwrap! (map-get? user-vault-positions { user: user, vault-id: vault-id }) ERR-POSITION-NOT-FOUND))
)

;; Get user protocol position
(define-read-only (get-user-protocol-position (user principal) (protocol-id uint))
  (ok (unwrap! (map-get? user-protocol-positions { user: user, protocol-id: protocol-id }) ERR-POSITION-NOT-FOUND))
)