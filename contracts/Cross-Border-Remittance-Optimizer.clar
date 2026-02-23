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
(define-constant ERR-NOT-CANCELLABLE (err u108))
(define-constant ERR-DAILY-LIMIT-EXCEEDED (err u109))
(define-constant ERR-WEEKLY-LIMIT-EXCEEDED (err u110))
(define-constant ERR-BENEFICIARY-EXISTS (err u111))
(define-constant ERR-BENEFICIARY-NOT-FOUND (err u112))
(define-constant ERR-MAX-BENEFICIARIES (err u113))

(define-constant DEFAULT-DAILY-LIMIT u10000000000)
(define-constant DEFAULT-WEEKLY-LIMIT u50000000000)
(define-constant BLOCKS-PER-DAY u144)
(define-constant BLOCKS-PER-WEEK u1008)

;; Fee optimization constants
(define-constant BASE-FEE-RATE u250) ;; 2.5% in basis points (10000 = 100%)
(define-constant CONGESTION-WINDOW u1440) ;; 24 hours in blocks (~10 min per block)
(define-constant MAX-CONGESTION-MULTIPLIER u200) ;; 2x max fee increase
(define-constant LOYALTY-BRONZE-THRESHOLD u5)
(define-constant LOYALTY-SILVER-THRESHOLD u15)
(define-constant LOYALTY-GOLD-THRESHOLD u50)

;; Routing optimization constants
(define-constant MIN-SAVINGS-THRESHOLD u100) ;; 1% minimum savings to use routing (in basis points)
(define-constant MAX-ROUTE-STEPS u3) ;; Maximum steps in routing path
(define-constant MAX-BENEFICIARIES u10)
(define-constant TRUSTED-FEE-DISCOUNT u10)

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

;; Routing optimization tracking
(define-map routing-savings principal uint)
(define-map optimal-routes {from: (string-ascii 5), to: (string-ascii 5)} (list 3 (string-ascii 5)))

(define-map user-transfer-limits principal {
    daily-limit: uint,
    weekly-limit: uint
})

(define-map user-transfer-history principal {
    daily-total: uint,
    daily-reset-block: uint,
    weekly-total: uint,
    weekly-reset-block: uint
})

(define-map trusted-beneficiaries {sender: principal, recipient: principal} {
    added-at: uint,
    total-transfers: uint
})

(define-map beneficiary-count principal uint)

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

;; Calculate conversion through intermediate currency
(define-private (calculate-route-conversion (amount uint) (currency1 (string-ascii 5)) (currency2 (string-ascii 5)) (currency3 (string-ascii 5)))
    (let (
        (rate1 (unwrap-panic (get-exchange-rate currency1 currency2)))
        (rate2 (unwrap-panic (get-exchange-rate currency2 currency3)))
        (intermediate-amount (/ (* amount rate1) u1000000))
        (final-amount (/ (* intermediate-amount rate2) u1000000))
    )
        final-amount
    )
)

;; Find optimal routing path
(define-private (find-optimal-route (from (string-ascii 5)) (to (string-ascii 5)) (amount uint))
    (let (
        (direct-rate (unwrap-panic (get-exchange-rate from to)))
        (direct-amount (/ (* amount direct-rate) u1000000))
        (usd-route (if (and (not (is-eq from "USD")) (not (is-eq to "USD")))
                      (some (calculate-route-conversion amount from "USD" to))
                      none))
        (eur-route (if (and (not (is-eq from "EUR")) (not (is-eq to "EUR")))
                      (some (calculate-route-conversion amount from "EUR" to))
                      none))
        (gbp-route (if (and (not (is-eq from "GBP")) (not (is-eq to "GBP")))
                      (some (calculate-route-conversion amount from "GBP" to))
                      none))
        (best-routed (fold max-amount-option (list usd-route eur-route gbp-route) none))
    )
        (match best-routed
            some-amount (if (> some-amount (+ direct-amount (/ (* direct-amount MIN-SAVINGS-THRESHOLD) u10000)))
                           {optimal: true, amount: some-amount, route: (get-route-path from to some-amount direct-amount)}
                           {optimal: false, amount: direct-amount, route: (list from to)})
            {optimal: false, amount: direct-amount, route: (list from to)}
        )
    )
)

;; Helper to find maximum amount option
(define-private (max-amount-option (current (optional uint)) (best (optional uint)))
    (match current
        some-current (match best
                        some-best (if (> some-current some-best) current best)
                        current)
        best)
)

(define-private (get-user-limits (user principal))
    (default-to {daily-limit: DEFAULT-DAILY-LIMIT, weekly-limit: DEFAULT-WEEKLY-LIMIT}
                (map-get? user-transfer-limits user))
)

(define-private (get-transfer-history (user principal))
    (default-to {daily-total: u0, daily-reset-block: u0, weekly-total: u0, weekly-reset-block: u0}
                (map-get? user-transfer-history user))
)

(define-private (check-transfer-limits (user principal) (amount uint))
    (let (
        (limits (get-user-limits user))
        (history (get-transfer-history user))
        (current-block stacks-block-height)
        (daily-reset-needed (> (- current-block (get daily-reset-block history)) BLOCKS-PER-DAY))
        (weekly-reset-needed (> (- current-block (get weekly-reset-block history)) BLOCKS-PER-WEEK))
        (current-daily (if daily-reset-needed u0 (get daily-total history)))
        (current-weekly (if weekly-reset-needed u0 (get weekly-total history)))
    )
        (if (> (+ current-daily amount) (get daily-limit limits))
            (err u109)
            (if (> (+ current-weekly amount) (get weekly-limit limits))
                (err u110)
                (ok true)))
    )
)

(define-private (update-transfer-history (user principal) (amount uint))
    (let (
        (history (get-transfer-history user))
        (current-block stacks-block-height)
        (daily-reset-needed (> (- current-block (get daily-reset-block history)) BLOCKS-PER-DAY))
        (weekly-reset-needed (> (- current-block (get weekly-reset-block history)) BLOCKS-PER-WEEK))
        (new-daily-total (if daily-reset-needed amount (+ (get daily-total history) amount)))
        (new-weekly-total (if weekly-reset-needed amount (+ (get weekly-total history) amount)))
        (new-daily-reset (if daily-reset-needed current-block (get daily-reset-block history)))
        (new-weekly-reset (if weekly-reset-needed current-block (get weekly-reset-block history)))
    )
        (map-set user-transfer-history user {
            daily-total: new-daily-total,
            daily-reset-block: new-daily-reset,
            weekly-total: new-weekly-total,
            weekly-reset-block: new-weekly-reset
        })
    )
)

;; Get route path based on best conversion
(define-private (get-route-path (from (string-ascii 5)) (to (string-ascii 5)) (routed-amount uint) (direct-amount uint))
    (let (
        (usd-amount (calculate-route-conversion u1000000 from "USD" to))
        (eur-amount (calculate-route-conversion u1000000 from "EUR" to))
        (gbp-amount (calculate-route-conversion u1000000 from "GBP" to))
    )
        (if (is-eq routed-amount usd-amount)
            (list from "USD" to)
            (if (is-eq routed-amount eur-amount)
                (list from "EUR" to)
                (if (is-eq routed-amount gbp-amount)
                    (list from "GBP" to)
                    (list from to))))
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
        (routing-result (find-optimal-route from-currency to-currency amount))
        (converted-amount (get amount routing-result))
        (routing-used (get optimal routing-result))
        (fee (calculate-dynamic-fee amount user))
        (is-trusted (is-some (map-get? trusted-beneficiaries {sender: user, recipient: recipient})))
        (adjusted-fee (if is-trusted (- fee (/ (* fee TRUSTED-FEE-DISCOUNT) u100)) fee))
        (remittance-id (+ (var-get remittance-counter) u1))
    )
        (asserts! (get registered user-data) ERR-USER-NOT-REGISTERED)
        (asserts! (get kyc-verified user-data) ERR-KYC-REQUIRED)
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (try! (check-transfer-limits user amount))
        
        (update-transfer-history user amount)
        
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
            fee: adjusted-fee,
            status: "PENDING",
            created-at: current-block,
            claimed-at: none
        })
        
        ;; Track routing savings if optimal route was used
        (if routing-used
            (let (
                (direct-rate (unwrap-panic (get-exchange-rate from-currency to-currency)))
                (direct-amount (/ (* amount direct-rate) u1000000))
                (savings (- converted-amount direct-amount))
                (current-savings (default-to u0 (map-get? routing-savings user)))
            )
                (map-set routing-savings user (+ current-savings savings))
                (map-set optimal-routes {from: from-currency, to: to-currency} (get route routing-result))
            )
            false
        )
        
        ;; Update volume tracking for congestion calculation
        (map-set block-volumes current-block 
                 (+ (default-to u0 (map-get? block-volumes current-block)) amount))
        (var-set total-volume (+ (var-get total-volume) amount))

        (if is-trusted
            (let (
                (ben-data (unwrap-panic (map-get? trusted-beneficiaries {sender: user, recipient: recipient})))
            )
                (map-set trusted-beneficiaries {sender: user, recipient: recipient}
                    (merge ben-data {total-transfers: (+ (get total-transfers ben-data) u1)}))
            )
            false
        )
        
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
        (map-set remittances remittance-id (merge remittance {
            status: "CLAIMED",
            claimed-at: (some current-block)
        }))
        (ok true)
    )
)

(define-public (cancel-remittance (remittance-id uint))
    (let (
        (remittance (unwrap! (map-get? remittances remittance-id) ERR-REMITTANCE-NOT-FOUND))
    )
        (asserts! (is-eq tx-sender (get sender remittance)) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get status remittance) "PENDING") ERR-NOT-CANCELLABLE)
        (map-set remittances remittance-id (merge remittance {
            status: "CANCELLED",
            claimed-at: none
        }))
        (ok true)
    )
)

(define-public (set-user-transfer-limits (user principal) (daily-limit uint) (weekly-limit uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (asserts! (<= daily-limit weekly-limit) ERR-INVALID-AMOUNT)
        (map-set user-transfer-limits user {
            daily-limit: daily-limit,
            weekly-limit: weekly-limit
        })
        (ok true)
    )
)

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

(define-public (add-trusted-beneficiary (recipient principal))
    (let (
        (user tx-sender)
        (user-data (unwrap! (map-get? users user) ERR-USER-NOT-REGISTERED))
        (current-count (default-to u0 (map-get? beneficiary-count user)))
    )
        (asserts! (get registered user-data) ERR-USER-NOT-REGISTERED)
        (asserts! (is-none (map-get? trusted-beneficiaries {sender: user, recipient: recipient})) ERR-BENEFICIARY-EXISTS)
        (asserts! (< current-count MAX-BENEFICIARIES) ERR-MAX-BENEFICIARIES)
        (map-set trusted-beneficiaries {sender: user, recipient: recipient} {
            added-at: stacks-block-height,
            total-transfers: u0
        })
        (map-set beneficiary-count user (+ current-count u1))
        (ok true)
    )
)

(define-public (remove-trusted-beneficiary (recipient principal))
    (let (
        (user tx-sender)
        (current-count (default-to u0 (map-get? beneficiary-count user)))
    )
        (asserts! (is-some (map-get? trusted-beneficiaries {sender: user, recipient: recipient})) ERR-BENEFICIARY-NOT-FOUND)
        (map-delete trusted-beneficiaries {sender: user, recipient: recipient})
        (map-set beneficiary-count user (if (> current-count u0) (- current-count u1) u0))
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

;; Get optimal routing information
(define-read-only (get-optimal-route (from (string-ascii 5)) (to (string-ascii 5)) (amount uint))
    (find-optimal-route from to amount)
)

;; Get routing savings for user
(define-read-only (get-user-routing-savings (user principal))
    (default-to u0 (map-get? routing-savings user))
)

;; Compare direct vs routed conversion
(define-read-only (compare-conversion-methods (from (string-ascii 5)) (to (string-ascii 5)) (amount uint))
    (let (
        (routing-result (find-optimal-route from to amount))
        (direct-rate (unwrap-panic (get-exchange-rate from to)))
        (direct-amount (/ (* amount direct-rate) u1000000))
        (optimal-amount (get amount routing-result))
        (savings (if (> optimal-amount direct-amount) (- optimal-amount direct-amount) u0))
        (savings-percentage (if (> direct-amount u0) (/ (* savings u10000) direct-amount) u0))
    )
        {
            direct-amount: direct-amount,
            optimal-amount: optimal-amount,
            savings: savings,
            savings-percentage: savings-percentage,
            route: (get route routing-result),
            uses-routing: (get optimal routing-result)
        }
    )
)

(define-read-only (get-cached-route (from (string-ascii 5)) (to (string-ascii 5)))
    (map-get? optimal-routes {from: from, to: to})
)

(define-read-only (is-trusted-beneficiary (sender principal) (recipient principal))
    (is-some (map-get? trusted-beneficiaries {sender: sender, recipient: recipient}))
)

(define-read-only (get-beneficiary-details (sender principal) (recipient principal))
    (map-get? trusted-beneficiaries {sender: sender, recipient: recipient})
)

(define-read-only (get-beneficiary-count (user principal))
    (default-to u0 (map-get? beneficiary-count user))
)

(define-read-only (get-remaining-limits (user principal))
    (let (
        (limits (get-user-limits user))
        (history (get-transfer-history user))
        (current-block stacks-block-height)
        (daily-reset-needed (> (- current-block (get daily-reset-block history)) BLOCKS-PER-DAY))
        (weekly-reset-needed (> (- current-block (get weekly-reset-block history)) BLOCKS-PER-WEEK))
        (current-daily (if daily-reset-needed u0 (get daily-total history)))
        (current-weekly (if weekly-reset-needed u0 (get weekly-total history)))
        (daily-remaining (- (get daily-limit limits) current-daily))
        (weekly-remaining (- (get weekly-limit limits) current-weekly))
    )
        {
            daily-limit: (get daily-limit limits),
            weekly-limit: (get weekly-limit limits),
            daily-used: current-daily,
            weekly-used: current-weekly,
            daily-remaining: daily-remaining,
            weekly-remaining: weekly-remaining,
            blocks-until-daily-reset: (if daily-reset-needed u0 (- BLOCKS-PER-DAY (- current-block (get daily-reset-block history)))),
            blocks-until-weekly-reset: (if weekly-reset-needed u0 (- BLOCKS-PER-WEEK (- current-block (get weekly-reset-block history))))
        }
    )
)

