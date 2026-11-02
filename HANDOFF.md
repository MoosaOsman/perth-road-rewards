# Perth Road Rewards — Handoff

**Purpose:** continue building this project in Claude Code. Read this whole file first, then carry on from **§8 Remaining work**. The owner (Moosa Osman, site manager, TotalEnergies Perth Road, Johannesburg) has asked for the work to be taken all the way to the end with minimal interruption. Make reasonable judgement calls and record each one in the design document.

Owner preferences: formal tone, detailed but not verbose. He pushes code to GitHub using **GitHub Desktop**.

---

## 1. What the system is

This is a fuel cashback loyalty scheme that runs **entirely separately from the Wayne pumps and the Namos POS**. Nothing is installed on them and nothing reads from them.

1. **Forecourt tablet (attendant):** the attendant taps the customer's NFC card and enters the pump, fuel grade and litres. This creates a **pending claim**.
2. **Kiosk tablet (cashier):** when the customer pays, the cashier checks the claim against the Namos till slip, enters the **Namos receipt number**, and approves or rejects it. Only approved claims credit cashback.
3. **Cash payout (kiosk):** the customer taps their card, the cashier verifies the last 3 digits of the customer's mobile number, and pays **cash from the till**. The cashier records it as a "Paid Out" in Namos.
4. **Manager (phone or laptop):** sets rates, settings, staff, devices, customers and adjustments, and views reports, CSV exports and the audit log.

## 2. Decisions made by the owner

| Topic | Decision |
|---|---|
| Integration | Fully external. No Namos or Wayne integration. |
| Earn rate | **Adjustable on the fly** by the manager, per grade or all grades. Starts at **10c/L** for all grades. |
| Redemption | **Paid out as cash** from the till. **R50 minimum.** No product exclusions. No expiry. |
| Payment flow | Customers pay **both at the kiosk and at the pump**. The cashier approves every claim using the Namos receipt number. |
| Tablets | **Android with built-in NFC** (to be purchased). |
| Daily cap | **150 L per card per day**, adjustable per customer (for taxis and fleets). |
| Backend | Supabase free tier (project created, see §4). |
| Name | **Perth Road Rewards** (neutral, no TotalEnergies trademark on cards). |
| Head office | The owner says head office approval is **not** required. |

## 3. Judgement calls already made (record these in the design doc)

1. **Balances are held in rand cents**, not abstract points.
2. **The rate is locked when the claim is captured.** A later rate change does not alter pending claims.
3. **Unapproved claims expire** after `claim_expiry_hours` (default 14 h, roughly one shift plus margin).
4. **Fraud controls:**
   - each Namos receipt number can be approved once only (case-insensitive);
   - staff cannot approve their own claims, and this applies to managers too;
   - identical claims within ±10 min are blocked;
   - one fill is capped at 200 L;
   - the per-card daily litre cap counts both pending and approved claims;
   - 5 wrong PINs lock the account for 15 min (the manager resets it by setting a new PIN);
   - every action is written to the audit log.
5. **Payout safeguards:**
   - the card must be present (tapped);
   - the cashier enters the last 3 digits of the customer's mobile number;
   - the maximum payout is **R1,000 per customer per day** (setting `max_payout_day_cents`);
   - payouts are allowed on kiosk or manager devices only.
6. **Authentication without Supabase Auth.** Each tablet holds a **device token** obtained once via an 8-character **pairing code** that the manager generates (valid 24 h, single use). Staff choose their name and enter a **4–6 digit PIN**. Every API call carries the token, staff ID and PIN. Tokens are stored only as a SHA-256 hash; PINs are stored as bcrypt hashes.
7. **First-run bootstrap.** `api_setup_first_manager` works only while the staff table is empty. It creates the first manager and makes the current browser the manager device.
8. **Offline forecourt claims.**
   - If the network is down, the tablet queues the claim in `localStorage` **without the PIN**. It submits later with `p_offline = true` and `p_pin = null`.
   - The server stores these with `pin_verified = false`. The cashier sees an "unverified/offline" badge, and reports count them per attendant.
   - `client_ref` (a UUID) makes retries idempotent.
   - A claim older than `claim_expiry_hours` is refused.
9. **Mobile numbers** are normalised to a 10-digit SA format (`+27…` becomes `0…`). The mobile number is unique per customer.
10. **Card UIDs** are normalised to uppercase hex with separators stripped. Only the card's unique ID is read. It is clonable with effort, which is an acceptable risk given cashier approval and the link to a registered customer. State this in the design doc.
11. **POPIA:** consent is required at registration (`popia_consent_at` is stored). Forecourt tablets never see balances. Mobile numbers are masked except on manager screens.
12. **Fuel grades seeded:** ULP93, ULP95, D50, D500. The pump count defaults to 8 (manager setting, 1–40).
13. **Days are Africa/Johannesburg local days** for caps, payout limits and reports.

## 4. Current state

**Supabase project:** `perth-road-rewards`
- Project ref / ID: `ospxqraxdraykoutmbmg`
- Region: eu-west-2 (London)
- Organisation: "Goras Property Manager" (`lbdvxaqillcnesjmevsm`)
- API URL: `https://ospxqraxdraykoutmbmg.supabase.co`
- Publishable key (safe for the browser): `sb_publishable_rR2r4P27Sw4xl6doiUpt9w_HHWfNQPP`

**Done:**
- Migrations `001_schema`, `002_functions` and `003_manager` are **applied** to the live project. The files are in `supabase/migrations/` and match what is deployed.
- `supabase/tests/test_scenarios.sql` ran against the live DB, and **all 60 checks passed**.

**⚠️ Test data is still in the database.** The clean-up was interrupted because the Supabase tool asked for confirmation of a destructive statement and the request timed out. Run this **first** (it needs the owner's confirmation in the Supabase prompt), then verify that all counts are 0:

```sql
delete from ledger; delete from payouts; delete from claims; delete from cards; delete from customers;
delete from audit_log; delete from earn_rates where set_by is not null; delete from devices; delete from staff;
update settings set pump_count = 8, updated_at = now() where id = 1;
select (select count(*) from staff) staff, (select count(*) from devices) devices,
       (select count(*) from customers) customers,
       (select json_agg(json_build_object('g', grade_code, 'r', cents_per_litre)) from earn_rates) rates;
-- expect 0, 0, 0 and four rates at 10.00
```

After clean-up, `api_setup_status()` should return `needs_setup: true`.

**Not done:** the tablet app, the documentation, and hosting. See §8.

## 5. Data model (summary)

| Table | Purpose |
|---|---|
| `settings` | Single row. `scheme_name`, `min_payout_cents` (5000), `max_payout_day_cents` (100000), `default_cap_litres` (150), `max_litres_per_fill` (200), `claim_expiry_hours` (14), `pump_count` (8), `max_pin_attempts` (5), `lockout_minutes` (15) |
| `fuel_grades` | code, name, sort_order, active |
| `earn_rates` | History of rates per grade. The current rate is the latest `effective_from` |
| `staff` | Name, role (`attendant` / `cashier` / `manager`), bcrypt `pin_hash`, active, lockout fields |
| `devices` | Name, kind (`forecourt` / `kiosk` / `manager`), `token_hash`, `pairing_code` and expiry, active, `last_seen` |
| `customers` | Name, mobile (unique), `popia_consent_at`, `daily_cap_litres` (null means default), status (`active` / `suspended`), notes |
| `cards` | `uid` (unique), customer, status (`active` / `blocked`), block reason |
| `claims` | `client_ref` (unique), card, customer, pump, grade, litres, locked rate, `cashback_cents`, status (`pending` / `approved` / `rejected` / `expired`), creator and decider, `pin_verified`, `namos_receipt_no` (unique when approved), `reject_reason` |
| `payouts` | Customer, card, amount, `namos_paidout_ref`, staff, device |
| `ledger` | Signed rand-cent entries: `earn` / `payout` / `adjust`. **Balance = sum(amount_cents)** |
| `audit_log` | Every sensitive action and every failed PIN |

All tables have RLS enabled with **no policies**, and all table privileges are revoked from `anon` and `authenticated`. Only `api_*` functions (SECURITY DEFINER) are executable by `anon`. Helper functions (`_auth`, `_balance` and so on) are not.

## 6. API reference

Call each function via `POST {URL}/rest/v1/rpc/<fn>` with headers `apikey: <publishable key>` and `Content-Type: application/json`, and a JSON body of named parameters (`p_…`).

Every function returns `{ok:true, data:{…}}` or `{ok:false, code, message}`. Show `message` to staff. Business errors are returned with HTTP 200, so always check `ok`.

**No authentication needed**
- `api_setup_status()` returns `{needs_setup, scheme_name}`.
- `api_setup_first_manager(p_name, p_pin, p_device_name)` returns `{token, kind:'manager'}`. Works only once.
- `api_pair_device(p_code)` returns `{token, kind, name}`.

**Device token only**
- `api_bootstrap(p_token)` returns `{device{id,kind,name}, settings, grades[{code,name,rate}], staff[{id,name,role}]}`. The staff list is filtered to the roles allowed on that device kind.

**Token, staff ID and PIN**

| Function | Device / role | Returns |
|---|---|---|
| `api_sign_in(p_token,p_staff,p_pin)` | any | `{name, role}` (checks the role is allowed on this device) |
| `api_card_lookup(…, p_uid)` | any | Customer name, masked mobile, card status, litres today, cap and remaining. Kiosk and manager also get `balance_cents`, `paid_out_today_cents` and payout limits; forecourt gets `null` for these |
| `api_claim_create(…, p_uid, p_pump, p_grade, p_litres, p_client_ref uuid, p_captured_at, p_offline)` | forecourt or manager; attendant or manager | `{claim_id, status, cashback_cents, customer_name, repeat}` |
| `api_claims_pending(…)` | kiosk or manager; cashier or manager | `{claims:[{id,pump_no,grade,litres,cashback_cents,captured_at,customer_name,card_last4,attendant,pin_verified,own_claim}]}` (expires stale claims first) |
| `api_claim_decide(…, p_claim, p_approve bool, p_receipt, p_reason)` | kiosk or manager | `{claim_id, status, balance_cents}` |
| `api_payout(…, p_uid, p_amount_cents, p_mobile_last3, p_namos_ref)` | kiosk or manager | `{payout_id, amount_cents, balance_cents, customer_name}` |
| `api_customer_register(…, p_name, p_mobile, p_consent, p_uid)` | kiosk or manager | Card info including balance |
| `api_card_replace(…, p_mobile, p_new_uid, p_reason)` | kiosk or manager | Blocks old cards, issues the new one, keeps the balance |
| `api_card_block(…, p_uid, p_reason)` | kiosk or manager | `{card_uid}` |
| `api_shift_summary(…)` | kiosk or manager | Today's figures for the signed-in cashier and for the site, plus the cashier's own payout list for Namos cash-up |

**Manager (manager device and manager role)**, all taking `(p_token, p_staff, p_pin, …)`:
- `api_mgr_dashboard` returns liability, customers, active cards, pending claims, the last 7 days, and attendant stats.
- `api_mgr_set_rate(p_grade|null=all, p_cents)` and `api_mgr_rates_history`.
- `api_mgr_update_settings(p_settings jsonb)` takes keys `scheme_name`, `min_payout_cents`, `max_payout_day_cents`, `default_cap_litres`, `max_litres_per_fill`, `claim_expiry_hours`, `pump_count`.
- `api_mgr_staff_list` and `api_mgr_staff_save(p_id|null, p_name, p_role, p_new_pin|null, p_active)`. Setting a new PIN also unlocks the account. A manager cannot deactivate or demote themselves.
- `api_mgr_devices`, `api_mgr_device_create(p_name, p_kind)` (returns a `pairing_code`), and `api_mgr_device_action(p_id, 'disable'|'enable'|'repair')`. `repair` issues a new code and invalidates the old token.
- `api_mgr_customers(p_search)`, `api_mgr_customer_detail(p_customer)`, `api_mgr_customer_update(p_customer, p_name, p_mobile, p_cap|null, p_status, p_notes)`, and `api_mgr_adjust(p_customer, p_amount_cents ±, p_note)`.
- `api_mgr_report(p_from date, p_to date)` returns `by_day`, `by_grade`, `by_attendant`, `by_cashier`, plus `claims[]` and `payouts[]` rows for CSV export.
- `api_mgr_audit(p_limit)`.

**Error codes the UI should handle:**
- Device and staff: `DEVICE`, `DEVICE_KIND`, `STAFF`, `ROLE`, `PIN`, `LOCKED`, `PIN_FORMAT`, `SETUP_DONE`, `PAIR`, `PAIR_EXPIRED`.
- Cards and customers: `CARD_UNKNOWN`, `CARD_BLOCKED`, `CARD_IN_USE`, `CARD`, `CUSTOMER_SUSPENDED`, `MOBILE`, `MOBILE_EXISTS`, `NO_CUSTOMER`, `CONSENT`, `NAME`.
- Claims: `PUMP`, `GRADE`, `LITRES`, `LITRES_MAX`, `CAP`, `DUPLICATE_CLAIM`, `TOO_OLD`, `REF`, `NOT_FOUND`, `NOT_PENDING`, `OWN_CLAIM`, `RECEIPT`, `RECEIPT_USED`, `REASON`.
- Payouts: `MOBILE_CHECK`, `AMOUNT`, `MIN`, `BALANCE`, `DAY_LIMIT`.
- Manager functions: `RATE`, `SETTINGS`, `SELF`, `RANGE`, `NEGATIVE`, `NOTE`.
- General: `DUPLICATE`, `SERVER`.

## 7. Repository layout

```
perth-road-rewards/
├── HANDOFF.md                       ← this file
├── supabase/
│   ├── migrations/001_schema.sql    ← applied
│   ├── migrations/002_functions.sql ← applied
│   ├── migrations/003_manager.sql   ← applied
│   └── tests/test_scenarios.sql     ← 60 checks; run only on an EMPTY DB, then wipe
├── app/                             ← TO BUILD (static site, GitHub Pages)
└── docs/                            ← TO WRITE
```

Suggested first steps in Claude Code: `git init`, commit as-is, create the GitHub repo `perth-road-rewards`, and have the owner publish it with GitHub Desktop.

## 8. Remaining work

### 8.1 Clear the test data
Run the SQL in §4 and confirm that all counts are 0.

### 8.2 Tablet app (`app/`)
Build a static PWA with no build step: `index.html`, `app.js`, `styles.css`, `config.js` (URL and publishable key), `manifest.webmanifest`, `sw.js` (to cache the app shell) and icons. Call the RPCs with plain `fetch`; no Supabase JS library is needed. The device kind (stored token) decides which mode loads.

**Common to all modes**
- **First run:** call `api_setup_status`. If `needs_setup`, show the "Set up as manager" form (name, PIN twice, device name). Otherwise show "Pair this tablet", which asks for the pairing code. Store the token in `localStorage` (`prr_token`).
- **Start-up:** call `api_bootstrap`. If it returns `DEVICE`, clear the token and return to pairing.
- **Sign-in:** show a grid of name tiles, then a PIN keypad, then `api_sign_in`. Keep the PIN **in memory only** for the session. Auto-lock after inactivity (forecourt 90 s, kiosk 5 min, manager 10 min) and provide a visible "Lock" button.
- **Card reading** (one module, three inputs):
  1. **Web NFC:** `NDEFReader.scan()` reading `event.serialNumber`. This needs Chrome on Android, HTTPS, and a user tap to start the scan.
  2. **Keyboard-wedge USB/Bluetooth reader:** fast keystrokes ending in Enter.
  3. **Manual entry:** type the number printed on the card.

  Normalise the UID the same way as the server (uppercase, alphanumeric only).
- Use large touch targets for gloved or hurried use, a high-contrast theme that works in sunlight on the forecourt, show the scheme name and device name in the header, and format rand as `R 1 234,56`.

**Forecourt mode (attendant)**
- Tap the card to call `api_card_lookup` and show the customer name and litres left today.
- Then pick the pump (button grid 1..pump_count), pick the grade (buttons with the current rate), and enter litres on a numeric keypad (2 decimals).
- Show the estimated cashback, confirm, and call `api_claim_create` with a new `crypto.randomUUID()` as `client_ref`.
- On success, show a big "Pending — customer must pay; cashier will approve" message, then reset.
- **Offline:** if the fetch fails on the network (not on an `ok:false` response), queue `{uid, pump, grade, litres, client_ref, captured_at, staff_id}` in `localStorage` **without the PIN**. Show a queue badge, retry every 30 s and on `online` events with `p_offline=true, p_pin=null`, and list failures with their reason. Card lookup is skipped when offline.

**Kiosk mode (cashier):** four tabs.
1. **Pending claims:** poll `api_claims_pending` every 10 s and play a sound on new items. Each card shows pump, grade, litres, cashback, customer, card last 4, attendant, age and an offline badge. *Approve* asks for the Namos receipt number on a large input. *Reject* offers reason buttons ("Customer didn't pay / left", "Wrong litres", "Wrong card", "Duplicate", "Other").
2. **Pay out:** tap the card to show the balance and today's paid-out amount. Ask for the last 3 mobile digits and the amount (default: the full balance, capped by the daily limit). Show the R50 minimum and an optional Namos paid-out reference. After confirming, show a large "PAY R xx,xx CASH FROM TILL — record Paid Out in Namos".
3. **Customers:** *Register* (tap the new card, name, mobile, POPIA consent checkbox with short consent wording), *Check balance*, *Replace lost card* (mobile + new card), *Block card*.
4. **Shift summary:** `api_shift_summary`, plus a printable cash-up list of payouts.

**Manager mode:** tabs for the following.
- **Dashboard:** KPI tiles plus a 7-day table and attendant table. Flag attendants with high reject, expired or offline-unverified counts.
- **Rates:** current rate per grade, "set all" or per grade, with history.
- **Settings.**
- **Staff:** add, edit, reset PIN, deactivate; show locked status.
- **Devices:** add, which shows a large pairing code with its expiry; disable, enable, re-pair; last seen.
- **Customers:** search, detail with ledger and claims, edit cap and status and notes, adjust with a required note.
- **Reports:** date range, tables, and **CSV export** of claims and payouts.
- **Audit log.**

**Hosting:** use GitHub Pages from `/app` (HTTPS is required for Web NFC). Document the GitHub Desktop steps for the owner. Netlify Drop is an alternative.

### 8.3 Documentation (`docs/`)
1. **Design document:** architecture, data model, rules, every judgement call in §3, the fraud model and residual risks (attendant–cashier collusion is the main one; mitigate with the daily Namos litres reconciliation), POPIA notes, and **tax note: ask the accountant how cash payouts are treated (discount vs. expense, VAT)**.
2. **Setup guide:** host the app; first-run manager setup; add staff; pair each tablet; Android kiosk setup (Chrome "Install app", screen pinning or a kiosk launcher, NFC on, never-sleep while charging); Supabase free tier notes (the project pauses after about 1 week with no activity, so daily use keeps it alive; back up via the dashboard).
3. **Hardware list:** 2+ Android NFC tablets (forecourt, kiosk) with rugged cases and mounts; NTAG215/216 or MIFARE cards (printed with scheme name and card number); optional USB NFC reader for the kiosk; Wi-Fi coverage on the forecourt. Include approximate ZAR prices **verified by web search** at the time of writing.
4. **Staff procedures:** one page each for attendants and cashiers, and a **daily manager reconciliation checklist**. Compare approved litres against Namos pump totals, reconcile payouts against Namos Paid Outs, review rejects, expired and offline claims, and check the audit log for PIN failures.

### 8.4 Verification before calling it done
- Run Supabase **security and performance advisors** and fix or justify any findings.
- Re-run `test_scenarios.sql` only if the DB is empty, then wipe again.
- Smoke-test the app end to end against the live project in a browser: setup, then pair a second tab as forecourt and a third as kiosk, then claim, approve, payout and report. Use the manual card entry in place of NFC.
- Make sure no test data is left behind, and confirm that `needs_setup` is true at handover. Alternatively, leave only what the owner sets up himself.

## 9. Notes for Claude Code
- Use the **Supabase MCP** with project ID `ospxqraxdraykoutmbmg`. Destructive SQL prompts the owner for confirmation, so warn him before running it.
- Do not put PINs or tokens in commits. The publishable key in `config.js` is designed to be public; the database is protected by RLS plus the RPC checks.
- If any function signature changes, add a new migration file (`004_…`). Do not edit the applied ones.
