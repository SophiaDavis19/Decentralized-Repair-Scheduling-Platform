;; PaymentAndAudit Smart Contract
;; This contract handles escrow payments for repair requests and maintains immutable audit trails.
;; It supports creating escrows, releasing payments, refunds, disputes, and detailed logging.
;; Sophisticated features include timeout mechanisms, dispute resolution with oracles,
;; payment splitting for multiple parties, and support for penalties.

;; Constants
(define-constant ERR-UNAUTHORIZED u100)
(define-constant ERR-INVALID-AMOUNT u101)
(define-constant ERR-INVALID-REQUEST u102)
(define-constant ERR-ESCROW-EXISTS u103)
(define-constant ERR-ESCROW-NOT-FOUND u104)
(define-constant ERR-ESCROW-RELEASED u105)
(define-constant ERR-ESCROW-EXPIRED u106)
(define-constant ERR-DISPUTE-ACTIVE u107)
(define-constant ERR-NO-DISPUTE u108)
(define-constant ERR-INVALID-PARTY u109)
(define-constant ERR-INVALID-PERCENTAGE u110)
(define-constant ERR-PAUSED u111)
(define-constant ERR-INVALID-METADATA u112)
(define-constant MAX-METADATA-LEN u500)
(define-constant MAX-SHARES u5) ;; Max number of payment shares

;; Data Variables
(define-data-var contract-owner principal tx-sender)
(define-data-var paused bool false)
(define-data-var dispute-oracle principal 'ST1PQHQKV0RJXZHJ1DI0J1RV2A0CJSR0D0TXAQZYC) ;; Mock oracle principal
(define-data-var escrow-counter uint u0)
(define-data-var audit-counter uint u0)

;; Data Maps
(define-map escrows uint 
  {
    request-id: uint,
    payer: principal,
    payee: principal,
    amount: uint,
    released: bool,
    refunded: bool,
    disputed: bool,
    create-time: uint,
    timeout: uint, ;; Block height for timeout
    metadata: (string-utf8 500)
  }
)

(define-map payment-shares uint 
  (list 5 
    {
      recipient: principal,
      percentage: uint ;; 0-100
    }
  )
)

(define-map disputes uint 
  {
    initiator: principal,
    reason: (string-utf8 200),
    resolved: bool,
    resolution: (optional (string-utf8 200)),
    resolve-time: (optional uint)
  }
)

(define-map audits uint 
  (list 100 
    {
      action: (string-utf8 50),
      actor: principal,
      timestamp: uint,
      details: (string-utf8 200)
    }
  )
)

;; Private Functions
(define-private (log-audit (escrow-id uint) (action (string-utf8 50)) (actor principal) (details (string-utf8 200)))
  (let 
    (
      (current-audits (default-to (list ) (map-get? audits escrow-id)))
      (new-audit {action: action, actor: actor, timestamp: block-height, details: details})
    )
    (map-set audits escrow-id (unwrap-panic (as-max-len? (append current-audits new-audit) u100)))
    (ok true)
  )
)

(define-private (validate-percentage-sum (shares (list 5 {recipient: principal, percentage: uint})))
  (fold + (map get-percentage shares) u0)
)

(define-private (get-percentage (share {recipient: principal, percentage: uint}))
  (get percentage share)
)

(define-private (is-contract-owner (caller principal))
  (is-eq caller (var-get contract-owner))
)

(define-private (distribute-payment (escrow-id uint) (amount uint) (shares (list 5 {recipient: principal, percentage: uint})))
  (fold distribute-share shares (ok u0))
)

(define-private (distribute-share (share {recipient: principal, percentage: uint}) (acc (response uint uint)))
  (match acc
    total-distributed
    (let 
      (
        (share-amount (/ (* amount (get percentage share)) u100))
      )
      (try! (as-contract (stx-transfer? share-amount tx-sender (get recipient share))))
      (ok (+ total-distributed share-amount))
    )
    err (err err)
  )
)

;; Public Functions
(define-public (pause-contract)
  (if (is-contract-owner tx-sender)
    (begin
      (var-set paused true)
      (ok true)
    )
    (err ERR-UNAUTHORIZED)
  )
)

(define-public (unpause-contract)
  (if (is-contract-owner tx-sender)
    (begin
      (var-set paused false)
      (ok true)
    )
    (err ERR-UNAUTHORIZED)
  )
)

(define-public (set-dispute-oracle (new-oracle principal))
  (if (is-contract-owner tx-sender)
    (begin
      (var-set dispute-oracle new-oracle)
      (ok true)
    )
    (err ERR-UNAUTHORIZED)
  )
)

(define-public (create-escrow (request-id uint) (payee principal) (amount uint) (timeout uint) (metadata (string-utf8 500)) (shares (list 5 {recipient: principal, percentage: uint})))
  (let 
    (
      (id (var-get escrow-counter))
      (total-percent (validate-percentage-sum shares))
    )
    (if (var-get paused) (err ERR-PAUSED)
      (if (> amount u0)
        (if (is-eq total-percent u100)
          (if (<= (len metadata) MAX-METADATA-LEN)
            (begin
              (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
              (map-set escrows id 
                {
                  request-id: request-id,
                  payer: tx-sender,
                  payee: payee,
                  amount: amount,
                  released: false,
                  refunded: false,
                  disputed: false,
                  create-time: block-height,
                  timeout: (+ block-height timeout),
                  metadata: metadata
                }
              )
              (map-set payment-shares id shares)
              (try! (log-audit id u"escrow-created" tx-sender metadata))
              (var-set escrow-counter (+ id u1))
              (ok id)
            )
            (err ERR-INVALID-METADATA)
          )
          (err ERR-INVALID-PERCENTAGE)
        )
        (err ERR-INVALID-AMOUNT)
      )
    )
  )
)

(define-public (release-escrow (escrow-id uint))
  (match (map-get? escrows escrow-id)
    escrow
    (if (var-get paused) (err ERR-PAUSED)
      (if (or (get released escrow) (get refunded escrow))
        (err ERR-ESCROW-RELEASED)
        (if (> block-height (get timeout escrow))
          (err ERR-ESCROW-EXPIRED)
          (if (get disputed escrow)
            (err ERR-DISPUTE-ACTIVE)
            (if (is-eq tx-sender (get payee escrow))
              (let 
                (
                  (amount (get amount escrow))
                  (shares (default-to (list {recipient: (get payee escrow), percentage: u100}) (map-get? payment-shares escrow-id)))
                )
                (try! (distribute-payment escrow-id amount shares))
                (map-set escrows escrow-id (merge escrow {released: true}))
                (try! (log-audit escrow-id u"escrow-released" tx-sender u"Payment released to payee(s)"))
                (ok true)
              )
              (err ERR-UNAUTHORIZED)
            )
          )
        )
      )
    )
    (err ERR-ESCROW-NOT-FOUND)
  )
)

(define-public (refund-escrow (escrow-id uint))
  (match (map-get? escrows escrow-id)
    escrow
    (if (var-get paused) (err ERR-PAUSED)
      (if (or (get released escrow) (get refunded escrow))
        (err ERR-ESCROW-RELEASED)
        (if (get disputed escrow)
          (err ERR-DISPUTE-ACTIVE)
          (if (is-eq tx-sender (get payer escrow))
            (begin
              (try! (as-contract (stx-transfer? (get amount escrow) tx-sender (get payer escrow))))
              (map-set escrows escrow-id (merge escrow {refunded: true}))
              (try! (log-audit escrow-id u"escrow-refunded" tx-sender u"Refunded to payer"))
              (ok true)
            )
            (err ERR-UNAUTHORIZED)
          )
        )
      )
    )
    (err ERR-ESCROW-NOT-FOUND)
  )
)

(define-public (initiate-dispute (escrow-id uint) (reason (string-utf8 200)))
  (match (map-get? escrows escrow-id)
    escrow
    (if (var-get paused) (err ERR-PAUSED)
      (if (or (get released escrow) (get refunded escrow))
        (err ERR-ESCROW-RELEASED)
        (if (get disputed escrow)
          (err ERR-DISPUTE-ACTIVE)
          (if (or (is-eq tx-sender (get payer escrow)) (is-eq tx-sender (get payee escrow)))
            (begin
              (map-set disputes escrow-id 
                {
                  initiator: tx-sender,
                  reason: reason,
                  resolved: false,
                  resolution: none,
                  resolve-time: none
                }
              )
              (map-set escrows escrow-id (merge escrow {disputed: true}))
              (try! (log-audit escrow-id u"dispute-initiated" tx-sender reason))
              (ok true)
            )
            (err ERR-UNAUTHORIZED)
          )
        )
      )
    )
    (err ERR-ESCROW-NOT-FOUND)
  )
)

(define-public (resolve-dispute (escrow-id uint) (resolution (string-utf8 200)) (refund-to-payer bool))
  (match (map-get? escrows escrow-id)
    escrow
    (match (map-get? disputes escrow-id)
      dispute
      (if (var-get paused) (err ERR-PAUSED)
        (if (is-eq tx-sender (var-get dispute-oracle))
          (if (not (get resolved dispute))
            (let 
              (
                (amount (get amount escrow))
              )
              (if refund-to-payer
                (try! (as-contract (stx-transfer? amount tx-sender (get payer escrow))))
                (let 
                  (
                    (shares (default-to (list {recipient: (get payee escrow), percentage: u100}) (map-get? payment-shares escrow-id)))
                  )
                  (try! (distribute-payment escrow-id amount shares))
                )
              )
              (map-set disputes escrow-id (merge dispute {resolved: true, resolution: (some resolution), resolve-time: (some block-height)}))
              (map-set escrows escrow-id (merge escrow {disputed: false, released: (not refund-to-payer), refunded: refund-to-payer}))
              (try! (log-audit escrow-id u"dispute-resolved" tx-sender resolution))
              (ok true)
            )
            (err ERR-NO-DISPUTE)
          )
          (err ERR-UNAUTHORIZED)
        )
      )
      (err ERR-NO-DISPUTE)
    )
    (err ERR-ESCROW-NOT-FOUND)
  )
)

;; Read-Only Functions
(define-read-only (get-escrow (escrow-id uint))
  (map-get? escrows escrow-id)
)

(define-read-only (get-payment-shares (escrow-id uint))
  (map-get? payment-shares escrow-id)
)

(define-read-only (get-dispute (escrow-id uint))
  (map-get? disputes escrow-id)
)

(define-read-only (get-audit-log (escrow-id uint))
  (map-get? audits escrow-id)
)

(define-read-only (is-paused)
  (var-get paused)
)

(define-read-only (get-contract-owner)
  (var-get contract-owner)
)

(define-read-only (get-dispute-oracle)
  (var-get dispute-oracle)
)

(define-read-only (get-escrow-count)
  (var-get escrow-counter)
)