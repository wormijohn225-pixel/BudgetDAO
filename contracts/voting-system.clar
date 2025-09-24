;; BudgetDAO - Voting System Contract
;; Governance contract handling community voting, member management, and proposal lifecycle

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-found (err u201))
(define-constant err-unauthorized (err u202))
(define-constant err-invalid-amount (err u203))
(define-constant err-already-voted (err u204))
(define-constant err-voting-ended (err u205))
(define-constant err-insufficient-stake (err u206))
(define-constant err-proposal-not-found (err u207))

;; Voting Parameters
(define-constant min-stake-to-propose u1000) ;; Minimum stake required to create proposals
(define-constant voting-period-blocks u1008) ;; ~7 days (assuming 144 blocks/day)
(define-constant quorum-percentage u25) ;; 25% minimum participation
(define-constant approval-threshold u50) ;; 50% approval required

;; Data Variables
(define-data-var total-members uint u0)
(define-data-var total-stake uint u0)
(define-data-var next-governance-proposal-id uint u1)
(define-data-var governance-paused bool false)

;; Member Management
(define-map dao-members
  { member: principal }
  {
    stake: uint,
    joined-at: uint,
    voting-power: uint,
    proposals-created: uint,
    votes-cast: uint,
    is-active: bool
  }
)

;; Governance Proposals
(define-map governance-proposals
  { proposal-id: uint }
  {
    proposer: principal,
    title: (string-ascii 100),
    description: (string-ascii 1000),
    proposal-type: (string-ascii 50),
    target-contract: (optional principal),
    function-name: (optional (string-ascii 100)),
    parameters: (optional (string-ascii 500)),
    created-at: uint,
    voting-ends-at: uint,
    votes-for: uint,
    votes-against: uint,
    total-voting-power: uint,
    status: (string-ascii 20),
    executed: bool
  }
)

;; Vote Records
(define-map proposal-votes
  { proposal-id: uint, voter: principal }
  {
    vote: bool, ;; true = for, false = against
    voting-power: uint,
    cast-at: uint
  }
)

;; Delegation System
(define-map vote-delegations
  { delegator: principal }
  {
    delegate: principal,
    delegated-power: uint,
    created-at: uint,
    is-active: bool
  }
)

;; Member Management Functions
(define-public (join-dao (initial-stake uint))
  (let
    (
      (existing-member (map-get? dao-members { member: tx-sender }))
    )
    (asserts! (> initial-stake u0) err-invalid-amount)
    (asserts! (not (var-get governance-paused)) err-unauthorized)
    
    (match existing-member
      member-data
      ;; If member exists, increase their stake
      (let
        (
          (new-stake (+ (get stake member-data) initial-stake))
          (new-voting-power (calculate-voting-power new-stake))
        )
        (map-set dao-members
          { member: tx-sender }
          (merge member-data { 
            stake: new-stake,
            voting-power: new-voting-power,
            is-active: true
          })
        )
        
        (var-set total-stake (+ (var-get total-stake) initial-stake))
        (ok new-stake)
      )
      ;; If new member, create entry
      (let
        (
          (voting-power (calculate-voting-power initial-stake))
        )
        (map-set dao-members
          { member: tx-sender }
          {
            stake: initial-stake,
            joined-at: stacks-block-height,
            voting-power: voting-power,
            proposals-created: u0,
            votes-cast: u0,
            is-active: true
          }
        )
        
        (var-set total-members (+ (var-get total-members) u1))
        (var-set total-stake (+ (var-get total-stake) initial-stake))
        
        (ok initial-stake)
      )
    )
  )
)

(define-public (increase-stake (additional-stake uint))
  (begin
    (asserts! (> additional-stake u0) err-invalid-amount)
    (asserts! (not (var-get governance-paused)) err-unauthorized)
    
    (match (map-get? dao-members { member: tx-sender })
      member-data
      (let
        (
          (new-stake (+ (get stake member-data) additional-stake))
          (new-voting-power (calculate-voting-power new-stake))
        )
        (map-set dao-members
          { member: tx-sender }
          (merge member-data { 
            stake: new-stake,
            voting-power: new-voting-power
          })
        )
        
        (var-set total-stake (+ (var-get total-stake) additional-stake))
        (ok new-stake)
      )
      err-not-found
    )
  )
)

;; Governance Proposal Functions
(define-public (create-governance-proposal 
    (title (string-ascii 100))
    (description (string-ascii 1000))
    (proposal-type (string-ascii 50))
    (target-contract (optional principal))
    (function-name (optional (string-ascii 100)))
    (parameters (optional (string-ascii 500)))
  )
  (let
    (
      (proposal-id (var-get next-governance-proposal-id))
      (voting-ends (+ stacks-block-height voting-period-blocks))
    )
    (asserts! (not (var-get governance-paused)) err-unauthorized)
    
    (match (map-get? dao-members { member: tx-sender })
      member-data
      (begin
        (asserts! (get is-active member-data) err-unauthorized)
        (asserts! (>= (get stake member-data) min-stake-to-propose) err-insufficient-stake)
        
        ;; Create proposal
        (map-set governance-proposals
          { proposal-id: proposal-id }
          {
            proposer: tx-sender,
            title: title,
            description: description,
            proposal-type: proposal-type,
            target-contract: target-contract,
            function-name: function-name,
            parameters: parameters,
            created-at: stacks-block-height,
            voting-ends-at: voting-ends,
            votes-for: u0,
            votes-against: u0,
            total-voting-power: u0,
            status: "voting",
            executed: false
          }
        )
        
        ;; Update member stats
        (map-set dao-members
          { member: tx-sender }
          (merge member-data { 
            proposals-created: (+ (get proposals-created member-data) u1)
          })
        )
        
        ;; Increment proposal ID
        (var-set next-governance-proposal-id (+ proposal-id u1))
        
        (ok proposal-id)
      )
      err-not-found
    )
  )
)

(define-public (cast-vote (proposal-id uint) (vote bool))
  (begin
    (asserts! (not (var-get governance-paused)) err-unauthorized)
    
    ;; Check if member exists and is active
    (match (map-get? dao-members { member: tx-sender })
      member-data
      (begin
        (asserts! (get is-active member-data) err-unauthorized)
        
        ;; Check if proposal exists and voting is active
        (match (map-get? governance-proposals { proposal-id: proposal-id })
          proposal
          (begin
            (asserts! (is-eq (get status proposal) "voting") err-voting-ended)
            (asserts! (<= stacks-block-height (get voting-ends-at proposal)) err-voting-ended)
            
            ;; Check if already voted
            (asserts! (is-none (map-get? proposal-votes { proposal-id: proposal-id, voter: tx-sender })) err-already-voted)
            
            (let
              (
                (voting-power (get voting-power member-data))
                (current-for (get votes-for proposal))
                (current-against (get votes-against proposal))
                (current-total (get total-voting-power proposal))
              )
              ;; Record the vote
              (map-set proposal-votes
                { proposal-id: proposal-id, voter: tx-sender }
                {
                  vote: vote,
                  voting-power: voting-power,
                  cast-at: stacks-block-height
                }
              )
              
              ;; Update proposal vote counts
              (map-set governance-proposals
                { proposal-id: proposal-id }
                (merge proposal {
                  votes-for: (if vote (+ current-for voting-power) current-for),
                  votes-against: (if vote current-against (+ current-against voting-power)),
                  total-voting-power: (+ current-total voting-power)
                })
              )
              
              ;; Update member stats
              (map-set dao-members
                { member: tx-sender }
                (merge member-data { 
                  votes-cast: (+ (get votes-cast member-data) u1)
                })
              )
              
              (ok voting-power)
            )
          )
          err-proposal-not-found
        )
      )
      err-not-found
    )
  )
)

(define-public (finalize-proposal (proposal-id uint))
  (begin
    (match (map-get? governance-proposals { proposal-id: proposal-id })
      proposal
      (begin
        (asserts! (is-eq (get status proposal) "voting") err-unauthorized)
        (asserts! (> stacks-block-height (get voting-ends-at proposal)) err-voting-ended)
        
        (let
          (
            (total-votes (get total-voting-power proposal))
            (votes-for (get votes-for proposal))
            (votes-against (get votes-against proposal))
            (total-possible-votes (var-get total-stake))
            (quorum-met (>= (* total-votes u100) (* total-possible-votes quorum-percentage)))
            (proposal-passed (and quorum-met (>= (* votes-for u100) (* (+ votes-for votes-against) approval-threshold))))
          )
          ;; Update proposal status
          (map-set governance-proposals
            { proposal-id: proposal-id }
            (merge proposal {
              status: (if proposal-passed "passed" "rejected")
            })
          )
          
          (ok {
            proposal-id: proposal-id,
            passed: proposal-passed,
            votes-for: votes-for,
            votes-against: votes-against,
            quorum-met: quorum-met
          })
        )
      )
      err-proposal-not-found
    )
  )
)

;; Query Functions
(define-read-only (get-member-info (member principal))
  (map-get? dao-members { member: member })
)

(define-read-only (get-governance-proposal (proposal-id uint))
  (map-get? governance-proposals { proposal-id: proposal-id })
)

(define-read-only (get-vote-record (proposal-id uint) (voter principal))
  (map-get? proposal-votes { proposal-id: proposal-id, voter: voter })
)

(define-read-only (get-dao-stats)
  {
    total-members: (var-get total-members),
    total-stake: (var-get total-stake),
    next-proposal-id: (var-get next-governance-proposal-id),
    governance-paused: (var-get governance-paused)
  }
)

(define-read-only (calculate-quorum-requirement)
  (* (var-get total-stake) quorum-percentage)
)

;; Private Functions
(define-private (calculate-voting-power (stake uint))
  ;; Simple linear relationship for now, could be more complex
  (if (<= stake u10000)
    stake
    (+ u10000 (/ (- stake u10000) u2)) ;; Diminishing returns for large stakes
  )
)

;; Administrative Functions
(define-public (pause-governance)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set governance-paused true)
    (ok true)
  )
)

(define-public (resume-governance)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set governance-paused false)
    (ok true)
  )
)

(define-public (deactivate-member (member principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (match (map-get? dao-members { member: member })
      member-data
      (begin
        (map-set dao-members
          { member: member }
          (merge member-data { is-active: false })
        )
        
        (ok member)
      )
      err-not-found
    )
  )
)
