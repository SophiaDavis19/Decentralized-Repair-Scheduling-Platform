# RepairChain: Decentralized Repair Scheduling Platform

## Overview

RepairChain is a Web3 project built on the Stacks blockchain using Clarity smart contracts. It addresses real-world problems in the device repair industry, such as inefficient scheduling, lack of transparency in repair processes, trust issues between users and service providers, and delays in triage and escalation. Traditional repair services often involve long wait times, opaque pricing, and no verifiable audit trails, leading to disputes and fraud.

RepairChain automates virtual triage for common issues (e.g., software diagnostics for phones, laptops, or appliances), schedules repairs, and escalates to in-person service centers when needed. All actions are recorded on the blockchain for immutable audit trails, ensuring transparency and accountability. Users pay via STX tokens, with escrows for secure transactions. This solves problems like:

- **Inefficiency**: Automated triage reduces manual assessments.
- **Transparency**: Immutable logs prevent tampering with repair history.
- **Trust**: Smart contracts enforce rules, reducing disputes.
- **Accessibility**: Decentralized, open to global users and providers.
- **Cost Savings**: Virtual fixes minimize physical visits.

The platform involves 6 core smart contracts (written in Clarity) to handle registration, requests, triage, scheduling, escalation, payments, and audits.

## Architecture

RepairChain uses Stacks' Proof-of-Transfer (PoX) for security and Bitcoin anchoring for immutability. Smart contracts interact via contract calls, with oracles for off-chain data (e.g., AI triage results). Frontend (not included here) could be a dApp built with React and stacks.js.

### Key Components

1. **UserRegistry Contract**: Manages user and service provider registrations.
2. **RepairRequest Contract**: Handles submission and tracking of repair requests.
3. **TriageContract**: Automates virtual triage logic.
4. **SchedulingContract**: Manages appointment scheduling for virtual/in-person sessions.
5. **EscalationContract**: Detects and handles escalations to physical repairs.
6. **PaymentAndAudit Contract**: Manages escrows, payments, and immutable audit trails.

## Smart Contracts

All contracts are written in Clarity. Below is a high-level description with pseudocode snippets. Full implementation would require testing on Stacks testnet.

### 1. UserRegistry.clar

Registers users (customers) and service providers (repair centers). Stores profiles with verification (e.g., KYC via oracles).

```clarity
(define-trait user-trait
  ((register-user (principal string) (response bool uint))
   (register-provider (principal string bool) (response bool uint))
   (get-user (principal) (response (optional {name: string, verified: bool}) uint))
   (get-provider (principal) (response (optional {name: string, location: string, certified: bool}) uint))))

(define-map users principal {name: string, verified: bool})
(define-map providers principal {name: string, location: string, certified: bool})

(define-public (register-user (user principal) (name string))
  (map-set users user {name: name, verified: false})
  (ok true))

(define-public (register-provider (provider principal) (name string) (location string) (certified bool))
  (map-set providers provider {name: name, location: location, certified: certified})
  (ok true))
```

### 2. RepairRequest.clar

Users submit repair requests with device details. Tracks status (pending, triaged, scheduled, completed).

```clarity
(define-constant STATUS_PENDING u0)
(define-constant STATUS_TRIAGED u1)
(define-constant STATUS_SCHEDULED u2)
(define-constant STATUS_COMPLETED u3)

(define-map requests uint {user: principal, device: string, issue: string, status: uint, request-time: uint})

(define-data-var request-counter uint u0)

(define-public (submit-request (device string) (issue string))
  (let ((id (var-get request-counter)))
    (map-set requests id {user: tx-sender, device: device, issue: issue, status: STATUS_PENDING, request-time: block-height})
    (var-set request-counter (+ id u1))
    (ok id)))

(define-public (update-status (id uint) (new-status uint))
  (match (map-get? requests id)
    request (if (is-eq (get user request) tx-sender)
              (begin
                (map-set requests id (merge request {status: new-status}))
                (ok true))
              (err u101))  ;; Unauthorized
    (err u102)))  ;; Not found
```

### 3. TriageContract.clar

Automates virtual triage using predefined rules or oracle inputs (e.g., AI diagnostic results). Determines if issue is virtual-fixable or needs escalation.

```clarity
(define-trait oracle-trait
  ((get-diagnosis (string) (response string uint))))

(define-public (perform-triage (request-id uint) (oracle principal))
  (match (contract-call? .repair-request get-request request-id)
    request (let ((diagnosis (contract-call? oracle get-diagnosis (get issue request))))
              (if (is-eq diagnosis "virtual")
                (contract-call? .repair-request update-status request-id STATUS_TRIAGED)
                (contract-call? .escalation-contract escalate request-id))
              (ok diagnosis))
    (err u102)))

;; Example rule-based triage (simplified)
(define-private (rule-based-triage (issue string))
  (if (or (is-eq issue "software-crash") (is-eq issue "battery-drain"))
    "virtual"
    "in-person"))
```

### 4. SchedulingContract.clar

Schedules virtual (video call) or in-person appointments. Uses time slots managed by providers.

```clarity
(define-map schedules principal (list 100 {time: uint, available: bool, request-id: (optional uint)}))

(define-public (add-slot (time uint))
  (match (map-get? schedules tx-sender)
    slots (map-set schedules tx-sender (append slots {time: time, available: true, request-id: none}))
    (map-set schedules tx-sender (list {time: time, available: true, request-id: none})))
  (ok true))

(define-public (book-slot (provider principal) (time uint) (request-id uint))
  (match (map-get? schedules provider)
    slots (let ((updated-slots (map (lambda (slot) (if (is-eq (get time slot) time)
                                                      (merge slot {available: false, request-id: (some request-id)})
                                                      slot)) slots)))
            (map-set schedules provider updated-slots)
            (contract-call? .repair-request update-status request-id STATUS_SCHEDULED)
            (ok true))
    (err u103)))  ;; No slots
```

### 5. EscalationContract.clar

Handles escalation from virtual to in-person. Notifies providers and updates request.

```clarity
(define-public (escalate (request-id uint))
  (match (contract-call? .repair-request get-request request-id)
    request (if (is-eq (get status request) STATUS_TRIAGED)
              (begin
                ;; Find nearest provider (oracle for location)
                (let ((provider (contract-call? .user-registry find-nearest-provider (get user request))))
                  (contract-call? .scheduling-contract book-in-person provider request-id))
                (contract-call? .repair-request update-status request-id u4)  ;; Escalated status
                (ok true))
              (err u104))  ;; Invalid status
    (err u102)))
```

### 6. PaymentAndAudit.clar

Manages escrow payments and logs all actions immutably in a map.

```clarity
(define-map escrows uint {request-id: uint, amount: uint, payer: principal, payee: principal, released: bool})
(define-map audits uint (list 100 {action: string, timestamp: uint, actor: principal}))

(define-data-var audit-counter uint u0)

(define-public (create-escrow (request-id uint) (amount uint) (payee principal))
  (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
  (map-set escrows request-id {request-id: request-id, amount: amount, payer: tx-sender, payee: payee, released: false})
  (log-audit "escrow-created" request-id tx-sender)
  (ok true))

(define-public (release-escrow (request-id uint))
  (match (map-get? escrows request-id)
    escrow (if (and (is-eq (get payee escrow) tx-sender) (not (get released escrow)))
             (begin
               (as-contract (stx-transfer? (get amount escrow) tx-sender (get payee escrow)))
               (map-set escrows request-id (merge escrow {released: true}))
               (log-audit "escrow-released" request-id tx-sender)
               (ok true))
             (err u105))  ;; Invalid
    (err u102)))

(define-private (log-audit (action string) (ref uint) (actor principal))
  (let ((id (var-get audit-counter)))
    (match (map-get? audits ref)
      logs (map-set audits ref (append logs {action: action, timestamp: block-height, actor: actor}))
      (map-set audits ref (list {action: action, timestamp: block-height, actor: actor})))
    (var-set audit-counter (+ id u1))))

(define-read-only (get-audit (ref uint))
  (map-get? audits ref))
```

## Deployment and Usage

### Prerequisites
- Install Clarinet (Stacks dev tool): `cargo install clarinet`
- Stacks wallet for testnet STX.

### Steps
1. Clone repo: `git clone https://github.com/your-repo/repairchain`
2. Initialize: `clarinet new repairchain && cd repairchain`
3. Add contracts: Create `.clar` files in `contracts/` with above code.
4. Test: `clarinet test`
5. Deploy to testnet: `clarinet deploy --testnet`
6. Interact: Use stacks.js in dApp to call contracts (e.g., submit-request).

## Future Enhancements
- Integrate AI oracles for advanced triage.
- NFT for repair certifications.
- Cross-chain payments.

## License
MIT License. See LICENSE.md for details.