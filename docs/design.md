# Perth Road Rewards — Design Document

| | |
|---|---|
| Site | TotalEnergies Perth Road, Johannesburg |
| Owner | Moosa Osman, Site Manager |
| Version | 1.0 — 2 November 2026 |
| Status | Built; awaiting live set-up |

---

## 1. Purpose and scope

Perth Road Rewards is a fuel cashback loyalty scheme. Registered customers carry an NFC card. Each fill earns cashback at a rate per litre set by the manager. Cashback is paid out in cash from the kiosk till once the balance reaches the minimum.

The scheme runs **entirely separately** from the Wayne pumps and the Namos point-of-sale system. Nothing is installed on them and nothing reads from them. The link between the two systems is made by people: the cashier checks every claim against the Namos till slip and records the Namos receipt number.

Head office approval is not required (owner's decision).

## 2. Owner decisions

| Topic | Decision |
|---|---|
| Integration | Fully external. No Namos or Wayne integration. |
| Earn rate | Adjustable at any time by the manager, per grade or for all grades. Starts at 10 c/L on every grade. |
| Redemption | Cash from the till. R20 minimum (owner, 9 Nov 2026; was R50). No product exclusions. No expiry of balances. |
| Payment flow | Customers pay at the kiosk or at the pump. The cashier approves every claim using the Namos receipt number. |
| Tablets | Android with built-in NFC. |
| Daily cap | 150 L per card per day by default; adjustable per customer (taxis, fleets). |
| Backend | Supabase (free tier). |
| Name | Perth Road Rewards — neutral, no TotalEnergies trademark on the cards. |

## 3. Architecture

```
 Forecourt tablet ─┐                                   ┌─ api_* functions (SECURITY DEFINER)
 (attendant)       │   HTTPS  POST /rest/v1/rpc/api_*  │    check device token + staff PIN,
 Kiosk tablet ─────┼──────────────────────────────────▶│    apply business rules,
 (cashier)         │   apikey: publishable key         │    write the ledger and audit log
 Manager phone ────┘                                   └─ PostgreSQL tables (RLS on, no policies)
 /laptop
        ▲
        │  static files (HTML/JS/CSS), service worker caches the app shell
 GitHub Pages (HTTPS)
```

* **Front end:** a static Progressive Web App in `app/` with no build step. It calls the database functions with plain `fetch`. The device's stored token decides which mode loads: forecourt, kiosk or manager.
* **Back end:** Supabase PostgreSQL. All business rules live in database functions (`supabase/migrations/002_functions.sql`, `003_manager.sql`). The browser cannot read or write any table directly.
* **Hosting:** GitHub Pages, published from the `app/` folder by a GitHub Actions workflow. HTTPS is required for Web NFC and is provided by GitHub Pages.

### 3.1 Process flow

1. **Capture (forecourt).** The attendant signs in, taps the customer's card, chooses pump, grade and litres. A **pending claim** is created with the earn rate locked at that moment.
2. **Approve (kiosk).** When the customer pays, the cashier matches the claim to the Namos till slip (pump, grade, litres) and enters the **Namos receipt number**. Only approval credits cashback. Unmatched claims are rejected with a reason; claims left undecided expire.
3. **Pay out (kiosk).** The customer taps the card. The cashier asks for the last three digits of the customer's mobile number, pays cash from the till and records a **Paid Out** in Namos.
4. **Manage.** The manager sets rates and limits, manages staff, tablets and customers, reconciles daily and reviews reports and the audit log.

## 4. Data model

| Table | Purpose |
|---|---|
| `settings` | Single row: scheme name, minimum payout (R20), daily payout limit (none; optional since migration 012), default daily cap (150 L), maximum per fill (200 L), claim expiry (14 h), pump count (8), PIN lockout (5 attempts / 15 min). |
| `fuel_grades` | ULP93, ULP95, D50, D500. |
| `earn_rates` | Rate history per grade. The current rate is the latest `effective_from`. |
| `staff` | Name, role (attendant / cashier / manager), bcrypt PIN hash, active flag, lockout fields. |
| `devices` | Tablet name, kind (forecourt / kiosk / manager), SHA-256 hash of its token, pairing code and expiry, active flag, last seen. |
| `customers` | Name, mobile (unique), POPIA consent time, optional personal daily cap, status, notes. |
| `cards` | Normalised card UID (unique), customer, status, block reason. |
| `claims` | One fill: card, customer, pump, grade, litres, locked rate, cashback, status (pending / approved / rejected / expired), who captured and who decided, PIN-verified flag, Namos receipt number, reject reason. |
| `payouts` | Cash paid: customer, card, amount, Namos Paid Out reference, cashier, device. |
| `ledger` | Signed amounts in rand cents: `earn`, `payout`, `adjust`. **Balance = sum of the customer's ledger.** |
| `audit_log` | Every sensitive action and every wrong PIN. |

Indexes cover every foreign key (migration `004_hardening.sql`).

## 4a. Verification (2 November 2026)

An end-to-end test was run in a browser against the live project, with three separate browser origins standing in for the manager device, a forecourt tablet and a kiosk tablet, using manual card entry and simulated keyboard-reader input. Covered: first-run manager set-up; adding staff; creating devices and pairing (including a lower-case code); sign-in on each device; customer registration (consent refusal, UID and +27 mobile normalisation); claim capture with the per-fill limit; an offline claim queued without the PIN and sent when the connection returned, then shown as unverified; approval with a receipt number and refusal of the same receipt on a second claim; rejection with a reason; manager balance adjustment; payout with a wrong and then a correct mobile check; shift summary; reports, CSV export, audit log and dashboard flags; rates and settings; auto-lock; and disable → re-enable of a tablet. Two app bugs and two server issues were found and fixed (§6.4). All test data was then removed; the database was left empty with `needs_setup = true`.

## 5. Business rules

| Rule | Value / behaviour |
|---|---|
| Earn | `cashback = round(litres × rate)` in cents, rate locked at capture. |
| Daily litre cap | 150 L per customer per local day (default); counts **pending and approved** claims. |
| Maximum per fill | 200 L. |
| Duplicate guard | Same card, pump, grade and litres within ±10 minutes is refused. |
| Claim expiry | Pending claims expire after 14 h (setting `claim_expiry_hours`). |
| Receipt | Namos receipt number required to approve; each number can be approved once only (case-insensitive). |
| Payout minimum | R20 (owner, 9 Nov 2026). |
| Payout daily limit | None at present (owner, 9 Nov 2026). Optional setting: blank = no limit; when set, per customer per local day. |
| Payout location | Kiosk or manager device only; card must be tapped; last 3 mobile digits must match. |
| Balance adjustment | Manager only, written note required, cannot make a balance negative. |
| Days | All "per day" limits and reports use the Africa/Johannesburg calendar day. |

## 6. Judgement calls

These were decided during design and build, without a specific instruction from the owner. Each can be revisited.

### 6.1 Back end (decided before build)

1. **Balances are held in rand cents**, not abstract points. Customers and staff think in rand; there is no conversion to explain.
2. **The rate is locked when the claim is captured.** A later rate change does not alter pending claims, so the attendant's estimate is what the customer receives.
3. **Unapproved claims expire** after `claim_expiry_hours` (default 14 h — one shift plus margin). A claim that was never paid for cannot be approved days later.
4. **Fraud controls:** single-use Namos receipt numbers; staff cannot approve or reject their own claims (managers included); identical claims within ±10 minutes are blocked; one fill is capped at 200 L; the per-card daily cap counts pending and approved claims; 5 wrong PINs lock the account for 15 minutes (the manager unlocks it by setting a new PIN); every sensitive action is written to the audit log.
5. **Payout safeguards:** card present; last 3 digits of the mobile number; an optional daily limit per customer (none at present); kiosk or manager devices only.
6. **Authentication without Supabase Auth.** Each tablet holds a device token, obtained once with a single-use 8-character pairing code (valid 24 h) generated by the manager. Staff choose their name and enter a 4–6 digit PIN. Every call carries token, staff ID and PIN. Tokens are stored only as SHA-256 hashes and PINs as bcrypt hashes. This avoids e-mail accounts for staff and suits shared tablets.
7. **First-run bootstrap.** `api_setup_first_manager` works only while the staff table is empty. It creates the first manager and makes that browser the manager device.
8. **Offline forecourt claims.** When the network is down, the forecourt tablet queues the claim in the browser's storage **without the PIN**. It is sent later flagged `p_offline = true`; the server stores it with `pin_verified = false`. The cashier sees an "OFFLINE · PIN NOT VERIFIED" badge and reports count these per attendant. A random `client_ref` makes resubmission safe. A queued claim older than the expiry period is refused.
9. **Mobile numbers** are normalised to the 10-digit South African format (`+27…` becomes `0…`) and are unique per customer.
10. **Card identity.** Only the card's unique ID (UID) is read, normalised to upper-case hexadecimal without separators. A UID can be cloned with effort and specialised equipment. This is accepted because a claim earns nothing until a cashier matches it to a paid Namos transaction, payouts require the card *and* the customer's mobile digits, and every card is tied to a registered customer.
11. **POPIA:** consent is required at registration and its time is stored; forecourt tablets never see balances; mobile numbers are masked except on manager screens (see item 30 for the mask format).
12. **Fuel grades** seeded as ULP93, ULP95, D50 and D500; pump count defaults to 8 (setting, 1–40).
13. **Days are Africa/Johannesburg local days** for caps, payout limits and reports.

### 6.2 Tablet app (decided during build)

14. **Single app, three modes.** One web app serves all tablets; the paired device type selects the mode. One URL to install and one code base to maintain.
15. **Manager device can also work the counter.** The manager mode includes the Pending claims, Pay out and customer-desk functions, so the manager can relieve the cashier from a phone or laptop. The server rules still apply (for example, a manager cannot approve a claim they captured).
16. **Offline sign-in on the forecourt only.** If the forecourt tablet is offline at sign-in, the attendant may still select their name; the PIN cannot be checked, so every claim in that session is queued and arrives marked unverified. Kiosk and manager sign-in require a connection because they handle money.
17. **The forecourt keeps the last staff list.** The latest start-up data (staff names, grades, rates, settings) is kept on the tablet so the forecourt can start without a network. No PINs or balances are stored.
18. **A disabled tablet keeps its token.** When the server reports the tablet is not registered or disabled, the app shows the pairing screen but keeps its old token and offers "Try the old pairing again". If the manager re-enables the device it works again without a new code; re-pairing issues a new code and permanently invalidates the old token. (The original brief said to clear the token; keeping it makes "disable → enable" work as the manager would expect.)
19. **The offline queue is sent even while the tablet is locked**, every 30 seconds and when the connection returns, because offline submissions do not use a PIN.
20. **Auto-lock times:** forecourt 90 s, kiosk 5 min, manager 10 min of inactivity. A visible Lock button is always present.
21. **Attendant review flag.** Dashboard and report rows are flagged "CHECK" when rejected + expired claims are 20 % or more of at least 5 claims, or when the attendant has any offline (PIN-unverified) claims. These thresholds are deliberately sensitive; adjust in `app/manager.js` (`attendantFlag`) if they flag too often.
22. **Payout amount defaults to the maximum allowed now** (the lower of the balance and the remaining daily limit). The cashier can lower it.
23. **New-claim sound** plays on the kiosk and manager devices only for claims the signed-in person did not capture.
24. **Screen kept awake** while the app is in use (Screen Wake Lock), where the browser allows it.
25. **Card number entry has three paths**: Web NFC (Android Chrome), a USB/Bluetooth keyboard-emulation reader, and typing the number printed on the card. The keyboard reader is recognised by keystrokes arriving faster than 100 ms apart and ending in Enter.
26. **POPIA consent wording** shown at registration: *"I agree that Perth Road Rewards may store my name, mobile number and fuel purchases to run this cashback scheme. My details will not be shared or used for marketing. I can ask the manager to see or delete my details at any time."*
27. **Hosting via GitHub Actions.** GitHub Pages can only publish a repository's root or `/docs` folder directly. Because `docs/` holds this documentation, a small workflow (`.github/workflows/pages.yml`) publishes `app/` instead. Nothing extra is needed from the owner beyond pushing with GitHub Desktop.

### 6.3 Database hardening (after advisor review)

28. **Migration `004_hardening.sql`** pins the `search_path` of eleven helper functions and adds an index for every foreign key. No behaviour changed. See §10 for the advisor findings that were accepted rather than changed.

### 6.4 Fixes from the end-to-end smoke test (migration `005_pairing_and_mask.sql`)

29. **Pairing codes use an unambiguous alphabet** (A–Z without I, L, O; digits 2–9). The original generator removed look-alike characters *before* upper-casing, so codes could still contain O, I or L, which staff would type as 0 or 1.
30. **The masked mobile now shows the first three digits** (`082 *** ****`) instead of the last three. The last three digits are the payout check; showing them on the kiosk screen let a cashier read them instead of asking the customer.

## 7. Security model

* The browser uses the Supabase **publishable key**, which is designed to be public.
* Every table has row-level security enabled and **no policies**, and all table privileges are revoked from the `anon` and `authenticated` roles. The browser therefore cannot read or write any table.
* Only the `api_*` functions may be executed by the browser. Each one checks the device token (and, except for set-up, pairing and start-up, the staff ID and PIN) and the role and device type permitted for that action. Helper functions (`_auth`, `_balance` and so on) cannot be called from the browser.
* Device tokens are 256-bit random values stored only as SHA-256 hashes. Pairing codes are single-use and expire after 24 hours.
* PINs are bcrypt-hashed and kept in tablet memory only for the signed-in session.
* Wrong PINs are counted; five in a row lock the person for 15 minutes and are audited.

**Residual technical risks**

* **A stolen, unlocked tablet** could be used until the manager disables it under Devices. Auto-lock limits the window; disable lost tablets immediately.
* **Offline claims are not PIN-checked.** Anyone holding a paired forecourt tablet could queue claims under an attendant's name while it is offline. The cashier still has to approve each one against a paid Namos slip, and the unverified flag is visible on the kiosk and in reports.
* **PIN guessing.** Four-digit PINs are protected by the lockout. Encourage six digits for managers.
* **Supabase free tier** has no point-in-time recovery; see the set-up guide for backups.

## 8. Fraud model

| Threat | Control |
|---|---|
| Attendant invents claims for a friend's card | Claim earns nothing until a cashier approves it against a Namos receipt; receipt numbers are single-use. |
| Same fill claimed twice | Duplicate guard (±10 min), single-use receipt numbers, daily litre cap. |
| Litres inflated | Cashier must match litres to the till slip; 200 L per-fill cap; daily cap; manager reconciles approved litres to Namos pump totals. |
| Cashier approves own claim | Blocked: nobody can decide a claim they captured. |
| Payout to the wrong person | Card must be present; last 3 mobile digits; daily payout limit. |
| Staff share or guess PINs | Personal PINs, lockout after 5 wrong attempts, audit of wrong PINs, auto-lock. |
| Lost or cloned card | Cashier blocks or replaces the card; balance moves to the new card. |
| Manager abuse of adjustments | Every adjustment needs a note and is audited; balances cannot go negative. |

**Main residual risk: attendant–cashier collusion.** If an attendant and a cashier work together, they can approve a fabricated claim using a genuine receipt number from an unrelated customer's transaction. Single-use receipts limit each receipt to one claim, but do not prove the receipt belonged to that customer.

**Mitigation — daily Namos reconciliation** (see the manager checklist in `staff-procedures.md`):

1. Compare approved litres per grade (Reports → By grade) with the Namos pump/grade litre totals for the same day. Approved scheme litres can never exceed litres sold, and a sudden rise in the share of litres claimed deserves a look.
2. Spot-check a few approved claims each day: look up the Namos receipt number and confirm pump, grade and litres match.
3. Reconcile cashback payouts against Namos Paid Outs.
4. Rotate staff pairings where practical, and review the attendant table for high reject, expired or offline counts.

## 9. POPIA notes

* **Personal information held:** name, mobile number, card UID, fuel purchase history (pump, grade, litres, time), cashback balance and payouts.
* **Purpose:** running the cashback scheme only. Not used for marketing; not shared.
* **Consent** is recorded at registration (`popia_consent_at`). The kiosk shows the consent wording for the cashier to read to the customer.
* **Minimisation:** no ID numbers, addresses or e-mail addresses are collected. Forecourt tablets do not see balances; mobile numbers are masked on staff screens.
* **Security safeguards:** see §7. Data is hosted by Supabase in the eu-west-2 (London) region. The operator should note this cross-border transfer in the site's POPIA records; the customer's consent covers storage for the scheme's purpose.
* **Access and deletion requests:** the manager can show a customer their record (Customers → detail). For deletion, suspend the customer and contact the system administrator to remove the record once the balance is nil; the ledger history should be kept as long as the accountant requires for tax records.
* **Information Officer:** the site's Information Officer (by default the owner/manager) is responsible for the scheme's POPIA compliance.

## 10. Supabase advisor review (2 November 2026)

| Finding | Level | Action |
|---|---|---|
| Function search path mutable (11 helper functions) | Warning | **Fixed** in `004_hardening.sql`. |
| Unindexed foreign keys (17) | Info | **Fixed** in `004_hardening.sql`. |
| RLS enabled, no policies (11 tables) | Info | **Accepted — intentional.** No table is meant to be reachable from the browser; access is only through the `api_*` functions. |
| Public / signed-in users can execute SECURITY DEFINER functions (`api_*`, 29 each) | Warning | **Accepted — intentional.** These functions *are* the API. Each one authenticates the device token and staff PIN itself. Helper functions are not executable by the browser. |
| Unused index (16, after `004`) | Info | **Accepted.** Reported because the database is still empty; these indexes exist to satisfy the foreign-key lint above and will be used as data grows. |

After `005`, a check confirmed that every helper function has a pinned search path and none is executable by the browser roles.

## 11. Tax note

Cashback is paid in cash from the till. **Ask the accountant** how these payouts should be treated:

* as a **discount** on fuel sales (reducing turnover and possibly output VAT), or
* as a **marketing/loyalty expense**;

and how they should be recorded in Namos (currently as a Paid Out), including VAT treatment and the documentation SARS would expect. The CSV exports under Reports (claims and payouts) provide the supporting detail.

Note that fuel prices are regulated in South Africa. Confirm with the accountant, and if necessary with the relevant authority, that cash-back on regulated fuel is acceptable in the form chosen.

## 12. Known limitations

* No automatic link to Namos: reconciliation is manual by design.
* The free Supabase tier pauses the project after about a week with no activity (daily use keeps it awake) and has limited backups.
* Web NFC works only in Chrome on Android, over HTTPS. iPhones and iPads cannot read cards in the browser; use manual entry or a USB reader there.
* Customer deletion is a database task (see §9), not a button in the app.
* Fuel grades are fixed in the database; adding a grade needs a small SQL change.
