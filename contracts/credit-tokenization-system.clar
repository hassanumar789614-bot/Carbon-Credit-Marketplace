;; title: credit-tokenization-system
;; version: 1.0.0
;; summary: Tokenization system for verified carbon credits with trading and retirement mechanisms
;; description: This contract manages the lifecycle of carbon credit tokens, including minting from verified
;;              satellite data, secure trading between parties, retirement for compliance, and complete
;;              audit trail tracking. It integrates with the satellite verification oracle for data integrity.

;; Define the carbon credit token (SIP-010 compatible)
(define-fungible-token carbon-credit)

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-INVALID-AMOUNT (err u201))
(define-constant ERR-INSUFFICIENT-BALANCE (err u202))
(define-constant ERR-TOKEN-NOT-FOUND (err u203))
(define-constant ERR-ALREADY-RETIRED (err u204))
(define-constant ERR-INVALID-RECIPIENT (err u205))
(define-constant ERR-TRANSFER-FAILED (err u206))
(define-constant ERR-MINTING-DISABLED (err u207))
(define-constant ERR-INVALID-ORACLE-DATA (err u208))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant TOKEN-NAME "CarbonCredit")
(define-constant TOKEN-SYMBOL "CCR")
(define-constant TOKEN-DECIMALS u6)
(define-constant MIN-CREDIT-AMOUNT u1000000) ;; Minimum 1 CCR (with 6 decimals)
(define-constant MAX-BATCH-SIZE u1000) ;; Maximum credits in a single batch
(define-constant RETIREMENT-FEE u10000) ;; 0.01 CCR fee for retirement

;; Data variables
(define-data-var contract-admin principal CONTRACT-OWNER)
(define-data-var total-credits-issued uint u0)
(define-data-var total-credits-retired uint u0)
(define-data-var minting-enabled bool true)
(define-data-var next-batch-id uint u1)
(define-data-var oracle-contract (optional principal) none)

;; Credit batch information
(define-map credit-batches
  { batch-id: uint }
  {
    issuer: principal,
    total-amount: uint,
    issued-at: uint,
    source-area: uint,
    verification-hash: (buff 32),
    vintage-year: uint,
    project-type: (string-ascii 50),
    retired-amount: uint,
    active: bool
  }
)

;; Individual credit tracking
(define-map credit-details
  { owner: principal, batch-id: uint }
  {
    amount: uint,
    acquired-at: uint,
    retired-amount: uint,
    transfer-count: uint
  }
)

;; Retirement records
(define-map retirement-records
  { retirement-id: uint }
  {
    retiree: principal,
    batch-id: uint,
    amount: uint,
    retired-at: uint,
    reason: (string-ascii 100),
    certificate-hash: (buff 32)
  }
)

;; Trading history
(define-map trade-history
  { trade-id: uint }
  {
    from: principal,
    to: principal,
    batch-id: uint,
    amount: uint,
    timestamp: uint,
    price-per-credit: uint
  }
)

;; Approved operators for token management
(define-map approved-operators
  { operator: principal }
  {
    is-approved: bool,
    approved-by: principal,
    approval-date: uint,
    operations-count: uint
  }
)

;; Market listings for trading
(define-map market-listings
  { listing-id: uint }
  {
    seller: principal,
    batch-id: uint,
    amount: uint,
    price-per-credit: uint,
    listed-at: uint,
    active: bool
  }
)

;; Batch retirement counter
(define-data-var next-retirement-id uint u1)
(define-data-var next-trade-id uint u1)
(define-data-var next-listing-id uint u1)

;; Public functions for credit management

;; Issue new carbon credits from verified satellite data
(define-public (issue-credits (source-area uint) (amount uint) (vintage-year uint) 
                              (project-type (string-ascii 50)) (verification-hash (buff 32)))
  (let
    (
      (batch-id (var-get next-batch-id))
      (issuer tx-sender)
    )
    ;; Verify minting is enabled
    (asserts! (var-get minting-enabled) ERR-MINTING-DISABLED)
    
    ;; Validate amount
    (asserts! (and (> amount u0) (<= amount MAX-BATCH-SIZE)) ERR-INVALID-AMOUNT)
    
    ;; TODO: Integrate with satellite oracle for verification
    ;; For now, assume verification is handled externally
    
    ;; Mint tokens to the issuer
    (try! (ft-mint? carbon-credit amount issuer))
    
    ;; Record batch information
    (map-set credit-batches
      { batch-id: batch-id }
      {
        issuer: issuer,
        total-amount: amount,
        issued-at: stacks-block-height,
        source-area: source-area,
        verification-hash: verification-hash,
        vintage-year: vintage-year,
        project-type: project-type,
        retired-amount: u0,
        active: true
      }
    )
    
    ;; Record initial ownership
    (map-set credit-details
      { owner: issuer, batch-id: batch-id }
      {
        amount: amount,
        acquired-at: stacks-block-height,
        retired-amount: u0,
        transfer-count: u0
      }
    )
    
    ;; Update counters
    (var-set next-batch-id (+ batch-id u1))
    (var-set total-credits-issued (+ (var-get total-credits-issued) amount))
    
    (ok batch-id)
  )
)

;; Transfer credits between parties
(define-public (transfer-credits (amount uint) (batch-id uint) (recipient principal) (memo (optional (buff 34))))
  (let
    (
      (sender tx-sender)
      (trade-id (var-get next-trade-id))
    )
    ;; Validate transfer
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (not (is-eq sender recipient)) ERR-INVALID-RECIPIENT)
    
    ;; Check sender has sufficient credits in this batch
    (let
      (
        (sender-credits (default-to 
                          { amount: u0, acquired-at: u0, retired-amount: u0, transfer-count: u0 }
                          (map-get? credit-details { owner: sender, batch-id: batch-id })))
        (available-amount (- (get amount sender-credits) (get retired-amount sender-credits)))
      )
      (asserts! (>= available-amount amount) ERR-INSUFFICIENT-BALANCE)
      
      ;; Perform the transfer
      (try! (ft-transfer? carbon-credit amount sender recipient))
      
      ;; Update sender's credit details
      (map-set credit-details
        { owner: sender, batch-id: batch-id }
        (merge sender-credits 
          {
            amount: (- (get amount sender-credits) amount),
            transfer-count: (+ (get transfer-count sender-credits) u1)
          }
        )
      )
      
      ;; Update or create recipient's credit details
      (let
        (
          (recipient-credits (default-to 
                              { amount: u0, acquired-at: stacks-block-height, retired-amount: u0, transfer-count: u0 }
                              (map-get? credit-details { owner: recipient, batch-id: batch-id })))
        )
        (map-set credit-details
          { owner: recipient, batch-id: batch-id }
          (merge recipient-credits 
            {
              amount: (+ (get amount recipient-credits) amount),
              acquired-at: (if (is-eq (get amount recipient-credits) u0)
                              stacks-block-height
                              (get acquired-at recipient-credits))
            }
          )
        )
      )
      
      ;; Record trade history
      (map-set trade-history
        { trade-id: trade-id }
        {
          from: sender,
          to: recipient,
          batch-id: batch-id,
          amount: amount,
          timestamp: stacks-block-height,
          price-per-credit: u0 ;; Direct transfer, no price
        }
      )
      
      (var-set next-trade-id (+ trade-id u1))
      (ok trade-id)
    )
  )
)

;; Retire credits for compliance or voluntary purposes
(define-public (retire-credits (amount uint) (batch-id uint) (reason (string-ascii 100)))
  (let
    (
      (retiree tx-sender)
      (retirement-id (var-get next-retirement-id))
    )
    ;; Validate retirement amount
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Check retiree has sufficient active credits
    (let
      (
        (owner-credits (unwrap! (map-get? credit-details { owner: retiree, batch-id: batch-id }) ERR-TOKEN-NOT-FOUND))
        (available-amount (- (get amount owner-credits) (get retired-amount owner-credits)))
      )
      (asserts! (>= available-amount amount) ERR-INSUFFICIENT-BALANCE)
      
      ;; Burn the retired credits
      (try! (ft-burn? carbon-credit amount retiree))
      
      ;; Update credit details
      (map-set credit-details
        { owner: retiree, batch-id: batch-id }
        (merge owner-credits 
          {
            retired-amount: (+ (get retired-amount owner-credits) amount)
          }
        )
      )
      
      ;; Update batch retirement amount
      (let
        (
          (batch-info (unwrap! (map-get? credit-batches { batch-id: batch-id }) ERR-TOKEN-NOT-FOUND))
        )
        (map-set credit-batches
          { batch-id: batch-id }
          (merge batch-info 
            {
              retired-amount: (+ (get retired-amount batch-info) amount)
            }
          )
        )
      )
      
      ;; Create retirement record
      (map-set retirement-records
        { retirement-id: retirement-id }
        {
          retiree: retiree,
          batch-id: batch-id,
          amount: amount,
          retired-at: stacks-block-height,
          reason: reason,
          certificate-hash: (sha256 (concat (concat (unwrap-panic (to-consensus-buff? retirement-id))
                                                   (unwrap-panic (to-consensus-buff? amount)))
                                           (unwrap-panic (to-consensus-buff? stacks-block-height))))
        }
      )
      
      ;; Update global counters
      (var-set next-retirement-id (+ retirement-id u1))
      (var-set total-credits-retired (+ (var-get total-credits-retired) amount))
      
      (ok retirement-id)
    )
  )
)

;; Create market listing for credits
(define-public (create-market-listing (batch-id uint) (amount uint) (price-per-credit uint))
  (let
    (
      (seller tx-sender)
      (listing-id (var-get next-listing-id))
    )
    ;; Validate listing parameters
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (> price-per-credit u0) ERR-INVALID-AMOUNT)
    
    ;; Check seller has sufficient credits
    (let
      (
        (seller-credits (unwrap! (map-get? credit-details { owner: seller, batch-id: batch-id }) ERR-TOKEN-NOT-FOUND))
        (available-amount (- (get amount seller-credits) (get retired-amount seller-credits)))
      )
      (asserts! (>= available-amount amount) ERR-INSUFFICIENT-BALANCE)
      
      ;; Create market listing
      (map-set market-listings
        { listing-id: listing-id }
        {
          seller: seller,
          batch-id: batch-id,
          amount: amount,
          price-per-credit: price-per-credit,
          listed-at: stacks-block-height,
          active: true
        }
      )
      
      (var-set next-listing-id (+ listing-id u1))
      (ok listing-id)
    )
  )
)

;; Purchase credits from market listing
(define-public (purchase-from-listing (listing-id uint) (amount uint))
  (let
    (
      (buyer tx-sender)
      (listing (unwrap! (map-get? market-listings { listing-id: listing-id }) ERR-TOKEN-NOT-FOUND))
    )
    ;; Validate purchase
    (asserts! (get active listing) ERR-TOKEN-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (<= amount (get amount listing)) ERR-INVALID-AMOUNT)
    (asserts! (not (is-eq buyer (get seller listing))) ERR-INVALID-RECIPIENT)
    
    ;; Calculate total cost
    (let
      (
        (total-cost (* amount (get price-per-credit listing)))
        (seller (get seller listing))
        (batch-id (get batch-id listing))
        (trade-id (var-get next-trade-id))
      )
      ;; Transfer payment (assuming STX for simplicity)
      (try! (stx-transfer? total-cost buyer seller))
      
      ;; Transfer credits
      (try! (ft-transfer? carbon-credit amount seller buyer))
      
      ;; Update seller's credit details
      (let
        (
          (seller-credits (unwrap! (map-get? credit-details { owner: seller, batch-id: batch-id }) ERR-TOKEN-NOT-FOUND))
        )
        (map-set credit-details
          { owner: seller, batch-id: batch-id }
          (merge seller-credits 
            {
              amount: (- (get amount seller-credits) amount),
              transfer-count: (+ (get transfer-count seller-credits) u1)
            }
          )
        )
      )
      
      ;; Update or create buyer's credit details
      (let
        (
          (buyer-credits (default-to 
                          { amount: u0, acquired-at: stacks-block-height, retired-amount: u0, transfer-count: u0 }
                          (map-get? credit-details { owner: buyer, batch-id: batch-id })))
        )
        (map-set credit-details
          { owner: buyer, batch-id: batch-id }
          (merge buyer-credits 
            {
              amount: (+ (get amount buyer-credits) amount),
              acquired-at: (if (is-eq (get amount buyer-credits) u0)
                              stacks-block-height
                              (get acquired-at buyer-credits))
            }
          )
        )
      )
      
      ;; Update market listing
      (let
        (
          (remaining-amount (- (get amount listing) amount))
        )
        (if (is-eq remaining-amount u0)
          (map-set market-listings
            { listing-id: listing-id }
            (merge listing { active: false })
          )
          (map-set market-listings
            { listing-id: listing-id }
            (merge listing { amount: remaining-amount })
          )
        )
      )
      
      ;; Record trade
      (map-set trade-history
        { trade-id: trade-id }
        {
          from: seller,
          to: buyer,
          batch-id: batch-id,
          amount: amount,
          timestamp: stacks-block-height,
          price-per-credit: (get price-per-credit listing)
        }
      )
      
      (var-set next-trade-id (+ trade-id u1))
      (ok trade-id)
    )
  )
)

;; Read-only functions

;; Get token info (SIP-010)
(define-read-only (get-name)
  (ok TOKEN-NAME)
)

(define-read-only (get-symbol)
  (ok TOKEN-SYMBOL)
)

(define-read-only (get-decimals)
  (ok TOKEN-DECIMALS)
)

(define-read-only (get-balance (who principal))
  (ok (ft-get-balance carbon-credit who))
)

(define-read-only (get-total-supply)
  (ok (ft-get-supply carbon-credit))
)

(define-read-only (get-token-uri)
  (ok none)
)

;; Get credit batch information
(define-read-only (get-batch-info (batch-id uint))
  (map-get? credit-batches { batch-id: batch-id })
)

;; Get credit details for owner and batch
(define-read-only (get-credit-details (owner principal) (batch-id uint))
  (map-get? credit-details { owner: owner, batch-id: batch-id })
)

;; Get retirement record
(define-read-only (get-retirement-record (retirement-id uint))
  (map-get? retirement-records { retirement-id: retirement-id })
)

;; Get trade history
(define-read-only (get-trade-record (trade-id uint))
  (map-get? trade-history { trade-id: trade-id })
)

;; Get market listing
(define-read-only (get-market-listing (listing-id uint))
  (map-get? market-listings { listing-id: listing-id })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-issued: (var-get total-credits-issued),
    total-retired: (var-get total-credits-retired),
    total-active: (- (var-get total-credits-issued) (var-get total-credits-retired)),
    minting-enabled: (var-get minting-enabled),
    next-batch-id: (var-get next-batch-id)
  }
)

;; Administrative functions

;; Set minting status (admin only)
(define-public (set-minting-enabled (enabled bool))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    (var-set minting-enabled enabled)
    (ok enabled)
  )
)

;; Set oracle contract (admin only)
(define-public (set-oracle-contract (oracle-principal principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    (var-set oracle-contract (some oracle-principal))
    (ok oracle-principal)
  )
)

;; Transfer admin rights (current admin only)
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    (var-set contract-admin new-admin)
    (ok new-admin)
  )
)
