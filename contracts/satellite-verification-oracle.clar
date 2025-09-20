;; title: satellite-verification-oracle
;; version: 1.0.0
;; summary: Satellite data integration oracle for forest coverage and carbon sequestration monitoring
;; description: This contract serves as an oracle for satellite data verification in the carbon credit marketplace.
;;              It processes satellite imagery data, monitors forest coverage changes, calculates carbon
;;              sequestration rates, and provides verified environmental data for carbon credit issuance.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-DATA (err u101))
(define-constant ERR-DATA-NOT-FOUND (err u102))
(define-constant ERR-ALREADY-EXISTS (err u103))
(define-constant ERR-INVALID-COORDINATES (err u104))
(define-constant ERR-STALE-DATA (err u105))
(define-constant ERR-INSUFFICIENT-COVERAGE (err u106))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-FOREST-COVERAGE u1000) ;; Minimum hectares for valid monitoring
(define-constant MAX-DATA-AGE u8640) ;; Maximum age in blocks (approximately 30 days)
(define-constant CARBON-SEQUESTRATION-RATE u20) ;; Average tonnes CO2 per hectare per year
(define-constant SATELLITE-DATA-PRECISION u10000) ;; Precision factor for calculations

;; Data variables
(define-data-var contract-admin principal CONTRACT-OWNER)
(define-data-var total-monitored-areas uint u0)
(define-data-var total-verified-credits uint u0)
(define-data-var oracle-status bool true)

;; Data structures for satellite monitoring
(define-map satellite-data
  { area-id: uint }
  {
    coordinates: { lat: int, lon: int, radius: uint },
    forest-coverage: uint,
    coverage-change: int,
    last-updated: uint,
    data-source: (string-ascii 50),
    verification-status: bool,
    carbon-sequestration: uint,
    monitoring-start: uint
  }
)

;; Historical data tracking
(define-map coverage-history
  { area-id: uint, timestamp: uint }
  {
    forest-coverage: uint,
    carbon-absorbed: uint,
    verification-hash: (buff 32),
    satellite-source: (string-ascii 50)
  }
)

;; Authorized data providers
(define-map authorized-oracles
  { oracle-address: principal }
  {
    is-active: bool,
    data-count: uint,
    accuracy-score: uint,
    last-submission: uint
  }
)

;; Area verification requests
(define-map verification-requests
  { request-id: uint }
  {
    requester: principal,
    area-id: uint,
    requested-at: uint,
    status: (string-ascii 20),
    verification-fee: uint
  }
)

;; Public functions for satellite data management

;; Submit new satellite data (only authorized oracles)
(define-public (submit-satellite-data (area-id uint) (lat int) (lon int) (radius uint) 
                                     (forest-coverage uint) (data-source (string-ascii 50))
                                     (verification-hash (buff 32)))
  (let
    (
      (caller tx-sender)
      (current-block stacks-block-height)
    )
    ;; Check if caller is authorized
    (asserts! (is-oracle-authorized caller) ERR-NOT-AUTHORIZED)
    
    ;; Validate coordinates and coverage data
    (asserts! (and (> radius u0) (< radius u100000)) ERR-INVALID-COORDINATES)
    (asserts! (> forest-coverage u0) ERR-INVALID-DATA)
    
    ;; Calculate carbon sequestration
    (let
      (
        (carbon-sequestered (* forest-coverage CARBON-SEQUESTRATION-RATE))
        (existing-data (map-get? satellite-data { area-id: area-id }))
      )
      ;; Update or create satellite data entry
      (map-set satellite-data
        { area-id: area-id }
        {
          coordinates: { lat: lat, lon: lon, radius: radius },
          forest-coverage: forest-coverage,
          coverage-change: (if (is-some existing-data)
                             (- (to-int forest-coverage) 
                                (to-int (get forest-coverage (unwrap-panic existing-data))))
                             0),
          last-updated: current-block,
          data-source: data-source,
          verification-status: true,
          carbon-sequestration: carbon-sequestered,
          monitoring-start: (if (is-some existing-data)
                              (get monitoring-start (unwrap-panic existing-data))
                              current-block)
        }
      )
      
      ;; Store historical record
      (map-set coverage-history
        { area-id: area-id, timestamp: current-block }
        {
          forest-coverage: forest-coverage,
          carbon-absorbed: carbon-sequestered,
          verification-hash: verification-hash,
          satellite-source: data-source
        }
      )
      
      ;; Update oracle statistics
      (update-oracle-stats caller)
      
      ;; Increment total monitored areas if new
      (if (is-none existing-data)
        (var-set total-monitored-areas (+ (var-get total-monitored-areas) u1))
        true
      )
      
      (ok area-id)
    )
  )
)

;; Request verification for a specific area
(define-public (request-area-verification (area-id uint) (verification-fee uint))
  (let
    (
      (request-id (+ (var-get total-monitored-areas) u1))
      (requester tx-sender)
    )
    ;; Validate area exists
    (asserts! (is-some (map-get? satellite-data { area-id: area-id })) ERR-DATA-NOT-FOUND)
    
    ;; Create verification request
    (map-set verification-requests
      { request-id: request-id }
      {
        requester: requester,
        area-id: area-id,
        requested-at: stacks-block-height,
        status: "pending",
        verification-fee: verification-fee
      }
    )
    
    (ok request-id)
  )
)

;; Update verification status (admin only)
(define-public (update-verification-status (request-id uint) (status (string-ascii 20)))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    
    (let
      (
        (request-data (unwrap! (map-get? verification-requests { request-id: request-id }) ERR-DATA-NOT-FOUND))
      )
      (map-set verification-requests
        { request-id: request-id }
        (merge request-data { status: status })
      )
      
      (ok true)
    )
  )
)

;; Authorize a new oracle (admin only)
(define-public (authorize-oracle (oracle-address principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    
    (map-set authorized-oracles
      { oracle-address: oracle-address }
      {
        is-active: true,
        data-count: u0,
        accuracy-score: u100,
        last-submission: stacks-block-height
      }
    )
    
    (ok true)
  )
)

;; Revoke oracle authorization (admin only)
(define-public (revoke-oracle (oracle-address principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    
    (let
      (
        (oracle-data (unwrap! (map-get? authorized-oracles { oracle-address: oracle-address }) ERR-DATA-NOT-FOUND))
      )
      (map-set authorized-oracles
        { oracle-address: oracle-address }
        (merge oracle-data { is-active: false })
      )
      
      (ok true)
    )
  )
)

;; Read-only functions for data access

;; Get satellite data for a specific area
(define-read-only (get-satellite-data (area-id uint))
  (map-get? satellite-data { area-id: area-id })
)

;; Get historical coverage data
(define-read-only (get-coverage-history (area-id uint) (timestamp uint))
  (map-get? coverage-history { area-id: area-id, timestamp: timestamp })
)

;; Check if data is fresh (within acceptable age limit)
(define-read-only (is-data-fresh (area-id uint))
  (match (map-get? satellite-data { area-id: area-id })
    data-entry
      (< (- stacks-block-height (get last-updated data-entry)) MAX-DATA-AGE)
    false
  )
)

;; Calculate carbon credits eligible for issuance
(define-read-only (calculate-carbon-credits (area-id uint))
  (match (map-get? satellite-data { area-id: area-id })
    data-entry
      (let
        (
          (coverage (get forest-coverage data-entry))
          (sequestration-rate (get carbon-sequestration data-entry))
        )
        ;; Only positive coverage changes generate credits
        (if (and (> coverage MIN-FOREST-COVERAGE) 
                 (>= (get coverage-change data-entry) 0)
                 (get verification-status data-entry))
          (some sequestration-rate)
          none
        )
      )
    none
  )
)

;; Get verification request details
(define-read-only (get-verification-request (request-id uint))
  (map-get? verification-requests { request-id: request-id })
)

;; Check oracle authorization status
(define-read-only (is-oracle-authorized (oracle-address principal))
  (match (map-get? authorized-oracles { oracle-address: oracle-address })
    oracle-data (get is-active oracle-data)
    false
  )
)

;; Get oracle statistics
(define-read-only (get-oracle-stats (oracle-address principal))
  (map-get? authorized-oracles { oracle-address: oracle-address })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-areas: (var-get total-monitored-areas),
    verified-credits: (var-get total-verified-credits),
    oracle-status: (var-get oracle-status),
    contract-admin: (var-get contract-admin)
  }
)

;; Validate coordinates are within acceptable range
(define-read-only (validate-coordinates (lat int) (lon int))
  (and
    (and (>= lat -90000000) (<= lat 90000000))   ;; Latitude in microdegrees
    (and (>= lon -180000000) (<= lon 180000000)) ;; Longitude in microdegrees
  )
)

;; Private helper functions

;; Update oracle statistics after data submission
(define-private (update-oracle-stats (oracle-address principal))
  (let
    (
      (current-stats (unwrap! (map-get? authorized-oracles { oracle-address: oracle-address }) false))
    )
    (map-set authorized-oracles
      { oracle-address: oracle-address }
      (merge current-stats 
        {
          data-count: (+ (get data-count current-stats) u1),
          last-submission: stacks-block-height
        }
      )
    )
  )
)

;; Administrative functions

;; Transfer admin rights (current admin only)
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    (var-set contract-admin new-admin)
    (ok true)
  )
)

;; Update oracle status (admin only)
(define-public (set-oracle-status (status bool))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    (var-set oracle-status status)
    (ok true)
  )
)
