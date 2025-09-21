;; title: Cross-Border-Remittance-Optimizer
;; version: 1.0.0
;; summary: Smart contract for optimized cross-border remittances with dynamic fee calculation
;; description: Enables secure, efficient international money transfers with intelligent fee optimization based on network congestion and user loyalty

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INVALID-AMOUNT (err u101))
(define-constant ERR-INSUFFICIENT-BALANCE (err u102))
(define-constant ERR-USER-NOT-REGISTERED (err u103))
(define-constant ERR-REMITTANCE-NOT-FOUND (err u104))
(define-constant ERR-ALREADY-CLAIMED (err u105))
(define-constant ERR-INVALID-CURRENCY (err u106))
(define-constant ERR-KYC-REQUIRED (err u107))

;; Fee optimization constants
(define-constant BASE-FEE-RATE u250) ;; 2.5% in basis points (10000 = 100%)
(define-constant CONGESTION-WINDOW u1440) ;; 24 hours in blocks (~10 min per block)
(define-constant MAX-CONGESTION-MULTIPLIER u200) ;; 2x max fee increase
(define-constant LOYALTY-BRONZE-THRESHOLD u5)
(define-constant LOYALTY-SILVER-THRESHOLD u15)
(define-constant LOYALTY-GOLD-THRESHOLD u50)

;; Data Variables
(define-data-var remittance-counter uint u0)
(define-data-var total-volume uint u0)

;; Exchange rates (stored as rate * 1000000 for 6 decimal precision)
(define-data-var usd-eur-rate uint u850000) ;; 1 USD = 0.85 EUR
(define-data-var usd-gbp-rate uint u790000) ;; 1 USD = 0.79 GBP
(define-data-var eur-gbp-rate uint u870000) ;; 1 EUR = 0.87 GBP

;; User registration and loyalty tracking
(define-map users principal {
    registered: bool,
    kyc-verified: bool,
    remittance-count: uint,
    loyalty-tier: (string-ascii 10),
    total-sent: uint
})

;; Remittance records
(define-map remittances uint {
    sender: principal,
    recipient: principal,
    from-currency: (string-ascii 5),
    to-currency: (string-ascii 5),
    amount: uint,
    converted-amount: uint,
    fee: uint,
    status: (string-ascii 10),
    created-at: uint,
    claimed-at: (optional uint)
})

;; Volume tracking for congestion analysis (block-height -> volume)
(define-map block-volumes uint uint)

;; Exchange rate helpers
(define-private (get-exchange-rate (from (string-ascii 5)) (to (string-ascii 5)))
    (if (and (is-eq from "USD") (is-eq to "EUR"))
        (ok (var-get usd-eur-rate))
        (if (and (is-eq from "USD") (is-eq to "GBP"))
            (ok (var-get usd-gbp-rate))
            (if (and (is-eq from "EUR") (is-eq to "GBP"))
                (ok (var-get eur-gbp-rate))
                (if (and (is-eq from "EUR") (is-eq to "USD"))
                    (ok (/ u1000000000000 (var-get usd-eur-rate)))
                    (if (and (is-eq from "GBP") (is-eq to "USD"))
                        (ok (/ u1000000000000 (var-get usd-gbp-rate)))
                        (if (and (is-eq from "GBP") (is-eq to "EUR"))
                            (ok (/ u1000000000000 (var-get eur-gbp-rate)))
                            (if (is-eq from to)
                                (ok u1000000)
                                ERR-INVALID-CURRENCY))))))))

;; Calculate dynamic fee based on congestion and loyalty
(define-private (calculate-dynamic-fee (amount uint) (user principal))
    (let (
        (user-data (default-to {registered: false, kyc-verified: false, remittance-count: u0, loyalty-tier: "NONE", total-sent: u0}
                                (map-get? users user)))
        (current-block stacks-block-height)
        (congestion-factor (calculate-congestion-factor current-block))
        (loyalty-discount (get-loyalty-discount (get remittance-count user-data)))
        (base-fee (/ (* amount BASE-FEE-RATE) u10000))
        (congestion-fee (/ (* base-fee congestion-factor) u100))
        (discounted-fee (- congestion-fee (/ (* congestion-fee loyalty-discount) u100)))
    )
        (if (> discounted-fee u0) discounted-fee u1)
    )
)

;; Calculate network congestion factor
(define-private (calculate-congestion-factor (current-block uint))
    (let (
        (window-start (if (> current-block CONGESTION-WINDOW) (- current-block CONGESTION-WINDOW) u0))
        (recent-volume (fold + (map get-block-volume (list window-start (+ window-start u100) (+ window-start u200) (+ window-start u300))) u0))
        (avg-volume (/ recent-volume u4))
        (congestion-ratio (if (> avg-volume u0) (min (/ (* recent-volume u100) avg-volume) MAX-CONGESTION-MULTIPLIER) u100))
    )
        congestion-ratio
    )
)

;; Helper to get block volume
(define-private (get-block-volume (block-num uint))
    (default-to u0 (map-get? block-volumes block-num))
)

;; Min helper function
(define-private (min (a uint) (b uint))
    (if (<= a b) a b)
)

;; Get loyalty discount percentage
(define-private (get-loyalty-discount (remittance-count uint))
    (if (>= remittance-count LOYALTY-GOLD-THRESHOLD)
        u20 ;; 20% discount for gold tier
        (if (>= remittance-count LOYALTY-SILVER-THRESHOLD)
            u15 ;; 15% discount for silver tier
            (if (>= remittance-count LOYALTY-BRONZE-THRESHOLD)
                u5 ;; 5% discount for bronze tier
                u0))) ;; No discount for new users
)

;; Update user loyalty tier
(define-private (update-loyalty-tier (user principal) (new-count uint))
    (let (
        (new-tier (if (>= new-count LOYALTY-GOLD-THRESHOLD)
                      "GOLD"
                      (if (>= new-count LOYALTY-SILVER-THRESHOLD)
                          "SILVER"
                          (if (>= new-count LOYALTY-BRONZE-THRESHOLD)
                              "BRONZE"
                              "NONE"))))
    )
        new-tier
    )
)

;; Public Functions

;; Register a new user
(define-public (register-user (kyc-verified bool))
    (let (
        (user tx-sender)
        (existing-user (map-get? users user))
    )
        (if (is-none existing-user)
            (begin
                (map-set users user {
                    registered: true,
                    kyc-verified: kyc-verified,
                    remittance-count: u0,
                    loyalty-tier: "NONE",
                    total-sent: u0
                })
                (ok true)
            )
            (ok false)
        )
    )
)

;; Send a remittance
(define-public (send-remittance (recipient principal) (from-currency (string-ascii 5)) (to-currency (string-ascii 5)) (amount uint))
    (let (
        (user tx-sender)
        (user-data (unwrap! (map-get? users user) ERR-USER-NOT-REGISTERED))
        (current-block stacks-block-height)
        (exchange-rate (unwrap! (get-exchange-rate from-currency to-currency) ERR-INVALID-CURRENCY))
        (converted-amount (/ (* amount exchange-rate) u1000000))
        (fee (calculate-dynamic-fee amount user))
        (remittance-id (+ (var-get remittance-counter) u1))
    )
        (asserts! (get registered user-data) ERR-USER-NOT-REGISTERED)
        (asserts! (get kyc-verified user-data) ERR-KYC-REQUIRED)
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        
        ;; Update remittance counter
        (var-set remittance-counter remittance-id)
        
        ;; Update user stats
        (let (
            (new-count (+ (get remittance-count user-data) u1))
            (new-total (+ (get total-sent user-data) amount))
            (new-tier (update-loyalty-tier user new-count))
        )
            (map-set users user (merge user-data {
                remittance-count: new-count,
                total-sent: new-total,
                loyalty-tier: new-tier
            }))
        )
        
        ;; Record remittance
        (map-set remittances remittance-id {
            sender: user,
            recipient: recipient,
            from-currency: from-currency,
            to-currency: to-currency,
            amount: amount,
            converted-amount: converted-amount,
            fee: fee,
            status: "PENDING",
            created-at: current-block,
            claimed-at: none
        })
        
        ;; Update volume tracking for congestion calculation
        (map-set block-volumes current-block 
                 (+ (default-to u0 (map-get? block-volumes current-block)) amount))
        (var-set total-volume (+ (var-get total-volume) amount))
        
        (ok remittance-id)
    )
)

;; Claim a remittance
(define-public (claim-remittance (remittance-id uint))
    (let (
        (remittance (unwrap! (map-get? remittances remittance-id) ERR-REMITTANCE-NOT-FOUND))
        (current-block stacks-block-height)
    )
        (asserts! (is-eq tx-sender (get recipient remittance)) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get status remittance) "PENDING") ERR-ALREADY-CLAIMED)
        
        ;; Update remittance status
        (map-set remittances remittance-id (merge remittance {
            status: "CLAIMED",
            claimed-at: (some current-block)
        }))
        
        (ok true)
    )
)

;; Admin function to update exchange rates
(define-public (set-exchange-rate (from (string-ascii 5)) (to (string-ascii 5)) (rate uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (if (and (is-eq from "USD") (is-eq to "EUR"))
            (var-set usd-eur-rate rate)
            (if (and (is-eq from "USD") (is-eq to "GBP"))
                (var-set usd-gbp-rate rate)
                (if (and (is-eq from "EUR") (is-eq to "GBP"))
                    (var-set eur-gbp-rate rate)
                    false)))
        (ok true)
    )
)

;; Read-only Functions

;; Get user information
(define-read-only (get-user (user principal))
    (map-get? users user)
)

;; Get remittance details
(define-read-only (get-remittance (remittance-id uint))
    (map-get? remittances remittance-id)
)

;; Get current fee estimate
(define-read-only (get-fee-estimate (amount uint) (user principal))
    (calculate-dynamic-fee amount user)
)

;; Get projected fee for future blocks (helps users time their transactions)
(define-read-only (get-projected-fee (amount uint) (user principal) (blocks-ahead uint))
    (let (
        (future-block (+ stacks-block-height blocks-ahead))
        (user-data (default-to {registered: false, kyc-verified: false, remittance-count: u0, loyalty-tier: "NONE", total-sent: u0}
                                (map-get? users user)))
        (loyalty-discount (get-loyalty-discount (get remittance-count user-data)))
        (base-fee (/ (* amount BASE-FEE-RATE) u10000))
        ;; Assume lower congestion in future (optimistic projection)
        (projected-congestion u80) ;; 80% congestion factor
        (congestion-fee (/ (* base-fee projected-congestion) u100))
        (discounted-fee (- congestion-fee (/ (* congestion-fee loyalty-discount) u100)))
    )
        (if (> discounted-fee u0) discounted-fee u1)
    )
)

;; Get exchange rate
(define-read-only (get-rate (from (string-ascii 5)) (to (string-ascii 5)))
    (get-exchange-rate from to)
)

;; Get network congestion level
(define-read-only (get-congestion-level)
    (calculate-congestion-factor stacks-block-height)
)

;; Get total platform statistics
(define-read-only (get-platform-stats)
    {
        total-remittances: (var-get remittance-counter),
        total-volume: (var-get total-volume),
        congestion-level: (calculate-congestion-factor stacks-block-height)
    }
)

