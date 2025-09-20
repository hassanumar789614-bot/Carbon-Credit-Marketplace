;; title: emission-offset-calculator
;; version: 1.0.0
;; summary: Calculates and matches carbon offsets with corporate emission data for compliance tracking
;; description: This contract processes corporate emission reports, determines required carbon credits for
;;              neutrality, connects emission sources with available credits, and generates compliance
;;              and impact reports. It integrates with credit tokenization for automated offset purchases.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-INVALID-DATA (err u301))
(define-constant ERR-EMISSION-NOT-FOUND (err u302))
(define-constant ERR-INSUFFICIENT-CREDITS (err u303))
(define-constant ERR-INVALID-PERIOD (err u304))
(define-constant ERR-ALREADY-OFFSET (err u305))
(define-constant ERR-CALCULATION-ERROR (err u306))
(define-constant ERR-INVALID-COMPANY (err u307))
(define-constant ERR-REPORT-LOCKED (err u308))

;; Constants for emission calculations
(define-constant CONTRACT-OWNER tx-sender)
(define-constant TONNES-TO-CREDITS u1000000) ;; 1 tonne CO2 = 1,000,000 microtonnes
(define-constant MIN-EMISSION-AMOUNT u1000) ;; Minimum 1 tonne CO2 for tracking
(define-constant MAX-REPORTING-DELAY u4320) ;; Maximum 15 days delay for reporting
(define-constant COMPLIANCE-THRESHOLD u95) ;; 95% offset requirement for compliance
(define-constant VOLUNTARY-MULTIPLIER u110) ;; 110% for voluntary over-offsetting

;; Emission factor constants (kg CO2 per unit)
(define-constant ELECTRICITY-FACTOR u400) ;; 0.4 kg CO2/kWh
(define-constant NATURAL-GAS-FACTOR u2000) ;; 2.0 kg CO2/m3
(define-constant GASOLINE-FACTOR u2300) ;; 2.3 kg CO2/liter
(define-constant DIESEL-FACTOR u2700) ;; 2.7 kg CO2/liter
(define-constant COAL-FACTOR u2400) ;; 2400 kg CO2/tonne

;; Data variables
(define-data-var contract-admin principal CONTRACT-OWNER)
(define-data-var total-companies uint u0)
(define-data-var total-emission-reports uint u0)
(define-data-var total-offsets-calculated uint u0)
(define-data-var next-report-id uint u1)
(define-data-var calculator-active bool true)

;; Company registration and profiles
(define-map registered-companies
  { company-id: principal }
  {
    company-name: (string-ascii 100),
    industry-sector: (string-ascii 50),
    registration-date: uint,
    contact-info: (string-ascii 200),
    compliance-status: (string-ascii 20),
    total-emissions: uint,
    total-offsets: uint,
    verified-reporter: bool
  }
)

;; Emission reports by companies
(define-map emission-reports
  { report-id: uint }
  {
    company-id: principal,
    reporting-period: { start-block: uint, end-block: uint },
    scope-1-emissions: uint, ;; Direct emissions
    scope-2-emissions: uint, ;; Indirect energy emissions
    scope-3-emissions: uint, ;; Other indirect emissions
    total-emissions: uint,
    verification-status: bool,
    submitted-at: uint,
    verified-at: uint,
    report-hash: (buff 32),
    methodology: (string-ascii 50)
  }
)

;; Emission sources breakdown
(define-map emission-sources
  { report-id: uint, source-type: (string-ascii 30) }
  {
    amount: uint,
    unit: (string-ascii 20),
    emission-factor: uint,
    calculated-co2: uint,
    verification-status: bool
  }
)

;; Offset calculations and requirements
(define-map offset-calculations
  { calculation-id: uint }
  {
    report-id: uint,
    company-id: principal,
    total-emissions: uint,
    required-offsets: uint,
    compliance-type: (string-ascii 20), ;; "mandatory" or "voluntary"
    offset-percentage: uint,
    calculated-at: uint,
    status: (string-ascii 20),
    credits-purchased: uint,
    remaining-deficit: uint
  }
)

;; Credit matching and allocation
(define-map credit-allocations
  { allocation-id: uint }
  {
    calculation-id: uint,
    company-id: principal,
    credit-batch-id: uint,
    credits-allocated: uint,
    allocation-date: uint,
    price-per-credit: uint,
    allocation-status: (string-ascii 20),
    retirement-scheduled: bool
  }
)

;; Compliance tracking
(define-map compliance-records
  { company-id: principal, period: uint }
  {
    total-emissions: uint,
    total-offsets: uint,
    compliance-percentage: uint,
    compliance-status: (string-ascii 20),
    penalty-amount: uint,
    certificate-issued: bool,
    period-end: uint
  }
)

;; Impact tracking and reporting
(define-map impact-metrics
  { metric-id: uint }
  {
    company-id: principal,
    period: uint,
    carbon-intensity: uint, ;; CO2 per unit output
    reduction-target: uint,
    actual-reduction: uint,
    improvement-percentage: int,
    benchmark-comparison: int,
    sustainability-score: uint
  }
)

;; Counter variables
(define-data-var next-calculation-id uint u1)
(define-data-var next-allocation-id uint u1)
(define-data-var next-metric-id uint u1)

;; Public functions for emission management

;; Register a new company for emission tracking
(define-public (register-company (company-name (string-ascii 100)) (industry-sector (string-ascii 50)) (contact-info (string-ascii 200)))
  (let
    (
      (company-id tx-sender)
    )
    ;; Check if company already registered
    (asserts! (is-none (map-get? registered-companies { company-id: company-id })) ERR-INVALID-COMPANY)
    
    ;; Register company
    (map-set registered-companies
      { company-id: company-id }
      {
        company-name: company-name,
        industry-sector: industry-sector,
        registration-date: stacks-block-height,
        contact-info: contact-info,
        compliance-status: "pending",
        total-emissions: u0,
        total-offsets: u0,
        verified-reporter: false
      }
    )
    
    (var-set total-companies (+ (var-get total-companies) u1))
    (ok company-id)
  )
)

;; Submit emission report for a period
(define-public (submit-emission-report (reporting-period-start uint) (reporting-period-end uint)
                                      (scope-1 uint) (scope-2 uint) (scope-3 uint)
                                      (methodology (string-ascii 50)))
  (let
    (
      (company-id tx-sender)
      (report-id (var-get next-report-id))
      (total-emissions (+ (+ scope-1 scope-2) scope-3))
    )
    ;; Validate company is registered
    (asserts! (is-some (map-get? registered-companies { company-id: company-id })) ERR-INVALID-COMPANY)
    
    ;; Validate reporting period
    (asserts! (< reporting-period-start reporting-period-end) ERR-INVALID-PERIOD)
    (asserts! (> total-emissions MIN-EMISSION-AMOUNT) ERR-INVALID-DATA)
    
    ;; Create emission report
    (map-set emission-reports
      { report-id: report-id }
      {
        company-id: company-id,
        reporting-period: { start-block: reporting-period-start, end-block: reporting-period-end },
        scope-1-emissions: scope-1,
        scope-2-emissions: scope-2,
        scope-3-emissions: scope-3,
        total-emissions: total-emissions,
        verification-status: false,
        submitted-at: stacks-block-height,
        verified-at: u0,
        report-hash: (sha256 (concat (concat (unwrap-panic (to-consensus-buff? report-id))
                                           (unwrap-panic (to-consensus-buff? total-emissions)))
                                     (unwrap-panic (to-consensus-buff? stacks-block-height)))),
        methodology: methodology
      }
    )
    
    ;; Update company totals
    (let
      (
        (company-data (unwrap! (map-get? registered-companies { company-id: company-id }) ERR-INVALID-COMPANY))
      )
      (map-set registered-companies
        { company-id: company-id }
        (merge company-data {
          total-emissions: (+ (get total-emissions company-data) total-emissions)
        })
      )
    )
    
    (var-set next-report-id (+ report-id u1))
    (var-set total-emission-reports (+ (var-get total-emission-reports) u1))
    (ok report-id)
  )
)

;; Add detailed emission sources to a report
(define-public (add-emission-source (report-id uint) (source-type (string-ascii 30)) (amount uint) 
                                   (unit (string-ascii 20)))
  (let
    (
      (company-id tx-sender)
      (report-data (unwrap! (map-get? emission-reports { report-id: report-id }) ERR-EMISSION-NOT-FOUND))
    )
    ;; Verify company owns this report
    (asserts! (is-eq company-id (get company-id report-data)) ERR-NOT-AUTHORIZED)
    
    ;; Calculate CO2 emissions based on source type
    (let
      (
        (emission-factor (get-emission-factor source-type))
        (calculated-co2 (* amount emission-factor))
      )
      (map-set emission-sources
        { report-id: report-id, source-type: source-type }
        {
          amount: amount,
          unit: unit,
          emission-factor: emission-factor,
          calculated-co2: calculated-co2,
          verification-status: false
        }
      )
      
      (ok calculated-co2)
    )
  )
)

;; Calculate required offsets for compliance
(define-public (calculate-required-offsets (report-id uint) (compliance-type (string-ascii 20)))
  (let
    (
      (company-id tx-sender)
      (report-data (unwrap! (map-get? emission-reports { report-id: report-id }) ERR-EMISSION-NOT-FOUND))
      (calculation-id (var-get next-calculation-id))
    )
    ;; Verify company owns this report
    (asserts! (is-eq company-id (get company-id report-data)) ERR-NOT-AUTHORIZED)
    
    ;; Validate report is verified
    (asserts! (get verification-status report-data) ERR-INVALID-DATA)
    
    (let
      (
        (total-emissions (get total-emissions report-data))
        (offset-percentage (if (is-eq compliance-type "voluntary")
                             VOLUNTARY-MULTIPLIER
                             COMPLIANCE-THRESHOLD))
        (required-offsets (/ (* total-emissions offset-percentage) u100))
      )
      ;; Create offset calculation record
      (map-set offset-calculations
        { calculation-id: calculation-id }
        {
          report-id: report-id,
          company-id: company-id,
          total-emissions: total-emissions,
          required-offsets: required-offsets,
          compliance-type: compliance-type,
          offset-percentage: offset-percentage,
          calculated-at: stacks-block-height,
          status: "pending",
          credits-purchased: u0,
          remaining-deficit: required-offsets
        }
      )
      
      (var-set next-calculation-id (+ calculation-id u1))
      (var-set total-offsets-calculated (+ (var-get total-offsets-calculated) u1))
      (ok calculation-id)
    )
  )
)

;; Allocate carbon credits to offset emissions
(define-public (allocate-credits-for-offset (calculation-id uint) (credit-batch-id uint) 
                                           (credits-amount uint) (price-per-credit uint))
  (let
    (
      (company-id tx-sender)
      (allocation-id (var-get next-allocation-id))
      (calc-data (unwrap! (map-get? offset-calculations { calculation-id: calculation-id }) ERR-EMISSION-NOT-FOUND))
    )
    ;; Verify company owns this calculation
    (asserts! (is-eq company-id (get company-id calc-data)) ERR-NOT-AUTHORIZED)
    
    ;; Validate allocation amount
    (asserts! (> credits-amount u0) ERR-INVALID-DATA)
    (asserts! (<= credits-amount (get remaining-deficit calc-data)) ERR-INSUFFICIENT-CREDITS)
    
    ;; Create credit allocation record
    (map-set credit-allocations
      { allocation-id: allocation-id }
      {
        calculation-id: calculation-id,
        company-id: company-id,
        credit-batch-id: credit-batch-id,
        credits-allocated: credits-amount,
        allocation-date: stacks-block-height,
        price-per-credit: price-per-credit,
        allocation-status: "allocated",
        retirement-scheduled: false
      }
    )
    
    ;; Update calculation progress
    (let
      (
        (new-purchased (+ (get credits-purchased calc-data) credits-amount))
        (new-deficit (- (get remaining-deficit calc-data) credits-amount))
      )
      (map-set offset-calculations
        { calculation-id: calculation-id }
        (merge calc-data {
          credits-purchased: new-purchased,
          remaining-deficit: new-deficit,
          status: (if (is-eq new-deficit u0) "completed" "partial")
        })
      )
    )
    
    (var-set next-allocation-id (+ allocation-id u1))
    (ok allocation-id)
  )
)

;; Generate compliance report for a period
(define-public (generate-compliance-report (period uint))
  (let
    (
      (company-id tx-sender)
      (company-data (unwrap! (map-get? registered-companies { company-id: company-id }) ERR-INVALID-COMPANY))
    )
    ;; Calculate compliance metrics for the period
    (let
      (
        (total-emissions (get total-emissions company-data))
        (total-offsets (get total-offsets company-data))
        (compliance-percentage (if (> total-emissions u0)
                                 (/ (* total-offsets u100) total-emissions)
                                 u0))
        (compliance-status (if (>= compliance-percentage COMPLIANCE-THRESHOLD)
                             "compliant"
                             "non-compliant"))
      )
      ;; Store compliance record
      (map-set compliance-records
        { company-id: company-id, period: period }
        {
          total-emissions: total-emissions,
          total-offsets: total-offsets,
          compliance-percentage: compliance-percentage,
          compliance-status: compliance-status,
          penalty-amount: (if (< compliance-percentage COMPLIANCE-THRESHOLD)
                            (* (- total-emissions total-offsets) u50) ;; 50 STX per tonne penalty
                            u0),
          certificate-issued: (>= compliance-percentage COMPLIANCE-THRESHOLD),
          period-end: stacks-block-height
        }
      )
      
      ;; Update company compliance status
      (map-set registered-companies
        { company-id: company-id }
        (merge company-data { compliance-status: compliance-status })
      )
      
      (ok compliance-percentage)
    )
  )
)

;; Read-only functions for data access

;; Get company registration details
(define-read-only (get-company-info (company-id principal))
  (map-get? registered-companies { company-id: company-id })
)

;; Get emission report details
(define-read-only (get-emission-report (report-id uint))
  (map-get? emission-reports { report-id: report-id })
)

;; Get emission source breakdown
(define-read-only (get-emission-source (report-id uint) (source-type (string-ascii 30)))
  (map-get? emission-sources { report-id: report-id, source-type: source-type })
)

;; Get offset calculation details
(define-read-only (get-offset-calculation (calculation-id uint))
  (map-get? offset-calculations { calculation-id: calculation-id })
)

;; Get credit allocation details
(define-read-only (get-credit-allocation (allocation-id uint))
  (map-get? credit-allocations { allocation-id: allocation-id })
)

;; Get compliance record
(define-read-only (get-compliance-record (company-id principal) (period uint))
  (map-get? compliance-records { company-id: company-id, period: period })
)

;; Calculate carbon intensity for a company
(define-read-only (calculate-carbon-intensity (company-id principal) (output-amount uint))
  (match (map-get? registered-companies { company-id: company-id })
    company-data
      (if (> output-amount u0)
        (some (/ (get total-emissions company-data) output-amount))
        none)
    none
  )
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-companies: (var-get total-companies),
    total-reports: (var-get total-emission-reports),
    total-calculations: (var-get total-offsets-calculated),
    calculator-active: (var-get calculator-active)
  }
)

;; Estimate required credits for emission amount
(define-read-only (estimate-offset-requirement (emission-amount uint) (compliance-type (string-ascii 20)))
  (let
    (
      (offset-percentage (if (is-eq compliance-type "voluntary")
                           VOLUNTARY-MULTIPLIER
                           COMPLIANCE-THRESHOLD))
    )
    (/ (* emission-amount offset-percentage) u100)
  )
)

;; Private helper functions

;; Get emission factor based on source type
(define-private (get-emission-factor (source-type (string-ascii 30)))
  (if (is-eq source-type "electricity")
    ELECTRICITY-FACTOR
    (if (is-eq source-type "natural-gas")
      NATURAL-GAS-FACTOR
      (if (is-eq source-type "gasoline")
        GASOLINE-FACTOR
        (if (is-eq source-type "diesel")
          DIESEL-FACTOR
          (if (is-eq source-type "coal")
            COAL-FACTOR
            u1000 ;; Default factor
          )
        )
      )
    )
  )
)

;; Administrative functions

;; Verify emission report (admin only)
(define-public (verify-emission-report (report-id uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    
    (let
      (
        (report-data (unwrap! (map-get? emission-reports { report-id: report-id }) ERR-EMISSION-NOT-FOUND))
      )
      (map-set emission-reports
        { report-id: report-id }
        (merge report-data {
          verification-status: true,
          verified-at: stacks-block-height
        })
      )
      
      (ok true)
    )
  )
)

;; Set company verification status (admin only)
(define-public (set-company-verification (company-id principal) (verified bool))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    
    (let
      (
        (company-data (unwrap! (map-get? registered-companies { company-id: company-id }) ERR-INVALID-COMPANY))
      )
      (map-set registered-companies
        { company-id: company-id }
        (merge company-data { verified-reporter: verified })
      )
      
      (ok verified)
    )
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

;; Toggle calculator status (admin only)
(define-public (set-calculator-status (active bool))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    (var-set calculator-active active)
    (ok active)
  )
)
