;; BudgetDAO - Budget Tracker Contract
;; Core contract for managing budget allocations, spending proposals, and financial tracking

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-insufficient-funds (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-invalid-amount (err u104))
(define-constant err-proposal-expired (err u105))
(define-constant err-proposal-not-approved (err u106))

;; Data Variables
(define-data-var total-budget uint u0)
(define-data-var next-proposal-id uint u1)
(define-data-var emergency-pause bool false)

;; Budget Categories
(define-map budget-categories
  { category-name: (string-ascii 50) }
  { 
    allocated-amount: uint,
    spent-amount: uint,
    created-at: uint,
    is-active: bool
  }
)

;; Spending Proposals
(define-map spending-proposals
  { proposal-id: uint }
  {
    proposer: principal,
    category: (string-ascii 50),
    amount: uint,
    description: (string-ascii 500),
    recipient: principal,
    created-at: uint,
    execution-deadline: uint,
    status: (string-ascii 20),
    executed: bool
  }
)

;; Transaction Records
(define-map transaction-records
  { tx-id: uint }
  {
    proposal-id: uint,
    amount: uint,
    category: (string-ascii 50),
    recipient: principal,
    executed-at: uint,
    tx-type: (string-ascii 20)
  }
)

(define-data-var next-tx-id uint u1)

;; Emergency Functions
(define-public (emergency-pause)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set emergency-pause true)
    (ok true)
  )
)

(define-public (emergency-resume)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set emergency-pause false)
    (ok true)
  )
)

;; Budget Category Functions
(define-public (create-budget-category (category-name (string-ascii 50)) (initial-allocation uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> initial-allocation u0) err-invalid-amount)
    (asserts! (not (var-get emergency-pause)) err-unauthorized)
    
    (map-set budget-categories
      { category-name: category-name }
      {
        allocated-amount: initial-allocation,
        spent-amount: u0,
        created-at: block-height,
        is-active: true
      }
    )
    
    ;; Update total budget
    (var-set total-budget (+ (var-get total-budget) initial-allocation))
    
    (ok category-name)
  )
)

(define-public (update-category-allocation (category-name (string-ascii 50)) (new-allocation uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> new-allocation u0) err-invalid-amount)
    
    (match (map-get? budget-categories { category-name: category-name })
      category-data
      (let 
        (
          (old-allocation (get allocated-amount category-data))
          (spent-amount (get spent-amount category-data))
        )
        (asserts! (>= new-allocation spent-amount) err-insufficient-funds)
        
        ;; Update category
        (map-set budget-categories
          { category-name: category-name }
          (merge category-data { allocated-amount: new-allocation })
        )
        
        ;; Update total budget
        (var-set total-budget 
          (+ (- (var-get total-budget) old-allocation) new-allocation)
        )
        
        (ok new-allocation)
      )
      err-not-found
    )
  )
)

;; Spending Proposal Functions
(define-public (create-spending-proposal 
    (category (string-ascii 50)) 
    (amount uint) 
    (description (string-ascii 500))
    (recipient principal)
    (execution-days uint)
  )
  (let
    (
      (proposal-id (var-get next-proposal-id))
      (deadline (+ block-height (* execution-days u144))) ;; Assuming ~144 blocks per day
    )
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (> execution-days u0) err-invalid-amount)
    (asserts! (not (var-get emergency-pause)) err-unauthorized)
    
    ;; Check if category exists and has sufficient funds
    (match (map-get? budget-categories { category-name: category })
      category-data
      (let
        (
          (available-funds (- (get allocated-amount category-data) (get spent-amount category-data)))
        )
        (asserts! (get is-active category-data) err-unauthorized)
        (asserts! (>= available-funds amount) err-insufficient-funds)
        
        ;; Create proposal
        (map-set spending-proposals
          { proposal-id: proposal-id }
          {
            proposer: tx-sender,
            category: category,
            amount: amount,
            description: description,
            recipient: recipient,
            created-at: block-height,
            execution-deadline: deadline,
            status: "pending",
            executed: false
          }
        )
        
        ;; Increment proposal ID
        (var-set next-proposal-id (+ proposal-id u1))
        
        (ok proposal-id)
      )
      err-not-found
    )
  )
)

(define-public (approve-proposal (proposal-id uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (not (var-get emergency-pause)) err-unauthorized)
    
    (match (map-get? spending-proposals { proposal-id: proposal-id })
      proposal
      (begin
        (asserts! (is-eq (get status proposal) "pending") err-unauthorized)
        (asserts! (<= block-height (get execution-deadline proposal)) err-proposal-expired)
        
        ;; Update proposal status
        (map-set spending-proposals
          { proposal-id: proposal-id }
          (merge proposal { status: "approved" })
        )
        
        (ok proposal-id)
      )
      err-not-found
    )
  )
)

(define-public (execute-proposal (proposal-id uint))
  (let
    (
      (tx-id (var-get next-tx-id))
    )
    (match (map-get? spending-proposals { proposal-id: proposal-id })
      proposal
      (begin
        (asserts! (is-eq (get status proposal) "approved") err-proposal-not-approved)
        (asserts! (not (get executed proposal)) err-unauthorized)
        (asserts! (<= block-height (get execution-deadline proposal)) err-proposal-expired)
        (asserts! (not (var-get emergency-pause)) err-unauthorized)
        
        ;; Update category spent amount
        (match (map-get? budget-categories { category-name: (get category proposal) })
          category-data
          (let
            (
              (new-spent (+ (get spent-amount category-data) (get amount proposal)))
            )
            ;; Update category
            (map-set budget-categories
              { category-name: (get category proposal) }
              (merge category-data { spent-amount: new-spent })
            )
            
            ;; Mark proposal as executed
            (map-set spending-proposals
              { proposal-id: proposal-id }
              (merge proposal { executed: true, status: "executed" })
            )
            
            ;; Record transaction
            (map-set transaction-records
              { tx-id: tx-id }
              {
                proposal-id: proposal-id,
                amount: (get amount proposal),
                category: (get category proposal),
                recipient: (get recipient proposal),
                executed-at: block-height,
                tx-type: "spending"
              }
            )
            
            ;; Increment transaction ID
            (var-set next-tx-id (+ tx-id u1))
            
            ;; Transfer funds (simulation - in real implementation would use STX transfer)
            (ok { proposal-id: proposal-id, amount: (get amount proposal), recipient: (get recipient proposal) })
          )
          err-not-found
        )
      )
      err-not-found
    )
  )
)

;; Query Functions
(define-read-only (get-category-info (category-name (string-ascii 50)))
  (map-get? budget-categories { category-name: category-name })
)

(define-read-only (get-proposal-info (proposal-id uint))
  (map-get? spending-proposals { proposal-id: proposal-id })
)

(define-read-only (get-transaction-info (tx-id uint))
  (map-get? transaction-records { tx-id: tx-id })
)

(define-read-only (get-total-budget)
  (var-get total-budget)
)

(define-read-only (get-next-proposal-id)
  (var-get next-proposal-id)
)

(define-read-only (get-available-funds (category-name (string-ascii 50)))
  (match (map-get? budget-categories { category-name: category-name })
    category-data
    (ok (- (get allocated-amount category-data) (get spent-amount category-data)))
    err-not-found
  )
)


;; Administrative Functions
(define-public (reject-proposal (proposal-id uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (match (map-get? spending-proposals { proposal-id: proposal-id })
      proposal
      (begin
        (asserts! (is-eq (get status proposal) "pending") err-unauthorized)
        
        ;; Update proposal status
        (map-set spending-proposals
          { proposal-id: proposal-id }
          (merge proposal { status: "rejected" })
        )
        
        (ok proposal-id)
      )
      err-not-found
    )
  )
)

(define-public (deactivate-category (category-name (string-ascii 50)))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (match (map-get? budget-categories { category-name: category-name })
      category-data
      (begin
        (map-set budget-categories
          { category-name: category-name }
          (merge category-data { is-active: false })
        )
        
        (ok category-name)
      )
      err-not-found
    )
  )
)




