;; Payment Processor Contract
;; Handles payment initiation, processing, and lifecycle management

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-INVALID-PAYMENT (err u201))
(define-constant ERR-PAYMENT-NOT-FOUND (err u202))
(define-constant ERR-INVALID-STATUS (err u203))
(define-constant ERR-INSUFFICIENT-BALANCE (err u204))
(define-constant ERR-PAYMENT-EXPIRED (err u205))
(define-constant ERR-INVALID-RECIPIENT (err u206))

;; Payment Status Constants
(define-constant STATUS-PENDING u0)
(define-constant STATUS-PROCESSING u1)
(define-constant STATUS-COMPLETED u2)
(define-constant STATUS-FAILED u3)
(define-constant STATUS-CANCELLED u4)
(define-constant STATUS-EXPIRED u5)

;; Data Variables
(define-data-var contract-owner principal tx-sender)
(define-data-var payment-counter uint u0)
(define-data-var processing-fee-rate uint u100) ;; 1% in basis points
(define-data-var payment-expiry-window uint u86400) ;; 24 hours

;; Data Maps
(define-map payments
  uint ;; payment-id
  {
    sender: principal,
    recipient: principal,
    recipient-name: (string-ascii 50),
    amount: uint,
    source-currency: (string-ascii 3),
    target-currency: (string-ascii 3),
    converted-amount: uint,
    status: uint,
    created-at: uint,
    updated-at: uint,
    expires-at: uint,
    processing-fee: uint,
    exchange-rate: uint,
    reference: (string-ascii 100)
  }
)

(define-map user-payments
  principal
  (list 100 uint) ;; List of payment IDs
)

(define-map payment-status-history
  { payment-id: uint, status: uint, timestamp: uint }
  { previous-status: uint, updated-by: principal, notes: (string-ascii 200) }
)

(define-map authorized-processors
  principal
  { active: bool, processed-count: uint, last-activity: uint }
)

;; Authorization Functions
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

(define-private (is-authorized-processor)
  (default-to false (get active (map-get? authorized-processors tx-sender)))
)

(define-private (is-payment-owner (payment-id uint))
  (match (map-get? payments payment-id)
    payment-info (is-eq tx-sender (get sender payment-info))
    false
  )
)

;; Admin Functions
(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)

(define-public (add-authorized-processor (processor principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (map-set authorized-processors processor {
      active: true,
      processed-count: u0,
      last-activity: u0
    })
    (ok true)
  )
)

(define-public (set-processing-fee-rate (new-rate uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-rate u1000) ERR-INVALID-PAYMENT) ;; Max 10%
    (var-set processing-fee-rate new-rate)
    (ok true)
  )
)

;; Payment Functions
(define-public (initiate-payment
  (amount uint)
  (source-currency (string-ascii 3))
  (target-currency (string-ascii 3))
  (recipient principal)
  (recipient-name (string-ascii 50))
  (reference (string-ascii 100))
)
  (let (
    (payment-id (+ (var-get payment-counter) u1))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    (expires-at (+ current-time (var-get payment-expiry-window)))
    (processing-fee (/ (* amount (var-get processing-fee-rate)) u10000))
  )
    (asserts! (> amount u0) ERR-INVALID-PAYMENT)
    (asserts! (not (is-eq recipient tx-sender)) ERR-INVALID-RECIPIENT)

    ;; Create payment record
    (map-set payments payment-id {
      sender: tx-sender,
      recipient: recipient,
      recipient-name: recipient-name,
      amount: amount,
      source-currency: source-currency,
      target-currency: target-currency,
      converted-amount: u0, ;; Will be set during processing
      status: STATUS-PENDING,
      created-at: current-time,
      updated-at: current-time,
      expires-at: expires-at,
      processing-fee: processing-fee,
      exchange-rate: u0, ;; Will be set during processing
      reference: reference
    })

    ;; Update payment counter
    (var-set payment-counter payment-id)

    ;; Add to user's payment list
    (match (map-get? user-payments tx-sender)
      existing-payments (map-set user-payments tx-sender
        (unwrap-panic (as-max-len? (append existing-payments payment-id) u100)))
      (map-set user-payments tx-sender (list payment-id))
    )

    ;; Record status history
    (map-set payment-status-history
      { payment-id: payment-id, status: STATUS-PENDING, timestamp: current-time }
      { previous-status: u999, updated-by: tx-sender, notes: "Payment initiated" }
    )

    (ok payment-id)
  )
)

(define-public (process-payment (payment-id uint) (exchange-rate uint) (converted-amount uint))
  (let (
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    (asserts! (is-authorized-processor) ERR-NOT-AUTHORIZED)

    (match (map-get? payments payment-id)
      payment-info (begin
        (asserts! (is-eq (get status payment-info) STATUS-PENDING) ERR-INVALID-STATUS)
        (asserts! (< current-time (get expires-at payment-info)) ERR-PAYMENT-EXPIRED)

        ;; Update payment with processing info
        (map-set payments payment-id (merge payment-info {
          status: STATUS-PROCESSING,
          updated-at: current-time,
          converted-amount: converted-amount,
          exchange-rate: exchange-rate
        }))

        ;; Record status change
        (map-set payment-status-history
          { payment-id: payment-id, status: STATUS-PROCESSING, timestamp: current-time }
          { previous-status: STATUS-PENDING, updated-by: tx-sender, notes: "Payment processing started" }
        )

        ;; Update processor stats
        (match (map-get? authorized-processors tx-sender)
          processor-info (map-set authorized-processors tx-sender {
            active: true,
            processed-count: (+ (get processed-count processor-info) u1),
            last-activity: current-time
          })
          false
        )

        (ok true)
      )
      ERR-PAYMENT-NOT-FOUND
    )
  )
)

(define-public (complete-payment (payment-id uint))
  (let (
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    (asserts! (is-authorized-processor) ERR-NOT-AUTHORIZED)

    (match (map-get? payments payment-id)
      payment-info (begin
        (asserts! (is-eq (get status payment-info) STATUS-PROCESSING) ERR-INVALID-STATUS)

        ;; Update payment status
        (map-set payments payment-id (merge payment-info {
          status: STATUS-COMPLETED,
          updated-at: current-time
        }))

        ;; Record status change
        (map-set payment-status-history
          { payment-id: payment-id, status: STATUS-COMPLETED, timestamp: current-time }
          { previous-status: STATUS-PROCESSING, updated-by: tx-sender, notes: "Payment completed successfully" }
        )

        (ok true)
      )
      ERR-PAYMENT-NOT-FOUND
    )
  )
)

(define-public (fail-payment (payment-id uint) (reason (string-ascii 200)))
  (let (
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    (asserts! (is-authorized-processor) ERR-NOT-AUTHORIZED)

    (match (map-get? payments payment-id)
      payment-info (begin
        (asserts! (or
          (is-eq (get status payment-info) STATUS-PENDING)
          (is-eq (get status payment-info) STATUS-PROCESSING)
        ) ERR-INVALID-STATUS)

        ;; Update payment status
        (map-set payments payment-id (merge payment-info {
          status: STATUS-FAILED,
          updated-at: current-time
        }))

        ;; Record status change
        (map-set payment-status-history
          { payment-id: payment-id, status: STATUS-FAILED, timestamp: current-time }
          { previous-status: (get status payment-info), updated-by: tx-sender, notes: reason }
        )

        (ok true)
      )
      ERR-PAYMENT-NOT-FOUND
    )
  )
)

(define-public (cancel-payment (payment-id uint))
  (let (
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    (asserts! (is-payment-owner payment-id) ERR-NOT-AUTHORIZED)

    (match (map-get? payments payment-id)
      payment-info (begin
        (asserts! (is-eq (get status payment-info) STATUS-PENDING) ERR-INVALID-STATUS)

        ;; Update payment status
        (map-set payments payment-id (merge payment-info {
          status: STATUS-CANCELLED,
          updated-at: current-time
        }))

        ;; Record status change
        (map-set payment-status-history
          { payment-id: payment-id, status: STATUS-CANCELLED, timestamp: current-time }
          { previous-status: STATUS-PENDING, updated-by: tx-sender, notes: "Payment cancelled by sender" }
        )

        (ok true)
      )
      ERR-PAYMENT-NOT-FOUND
    )
  )
)

;; Query Functions
(define-read-only (get-payment (payment-id uint))
  (map-get? payments payment-id)
)

(define-read-only (get-user-payments (user principal))
  (default-to (list) (map-get? user-payments user))
)

(define-read-only (get-payment-status-history (payment-id uint) (status uint) (timestamp uint))
  (map-get? payment-status-history { payment-id: payment-id, status: status, timestamp: timestamp })
)

(define-read-only (is-payment-expired (payment-id uint))
  (match (map-get? payments payment-id)
    payment-info (let (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
      (> current-time (get expires-at payment-info))
    )
    false
  )
)

(define-read-only (get-payment-counter)
  (var-get payment-counter)
)
