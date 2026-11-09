# Perth Road Rewards — Staff Procedures

Three one-page procedures: **Attendant**, **Cashier** and the **Manager's daily reconciliation**. Print each page and keep it at the workstation.

---

## Attendant (forecourt tablet)

**Start of shift**
1. Open the app. Tap your name and enter your PIN. Never tell anyone your PIN.
2. If the screen shows **Start card reader**, tap it once.

**For every Rewards customer**
1. **Before or after filling, tap the customer's card** on the back of the tablet (the marked spot).
   * The customer's name and litres left today appear.
   * "Card not registered", "blocked" or "limit reached": tell the customer politely to see the cashier. Do not capture a claim.
   * If the card will not read, type the number printed on the card and tap **Use**.
2. Tap the **pump number**. The grade fills in by itself (each pump button shows its grade). Only on a pump that sells more than one grade, also tap the **fuel grade**.
3. Type the **litres exactly as shown on the pump**, e.g. 42,57.
4. Check the summary on the green button, then tap **Submit**.
5. The screen shows **PENDING**. Tell the customer: *"Your cashback is pending. Please pay, and the cashier will approve it."*
6. Tap **Next customer**.

**Rules**
* One claim per fill. Never capture a claim for a fill that did not happen or for another person's card.
* If you make a mistake, tell the cashier: they will reject the claim and you capture it again correctly.
* You cannot see customer balances. Send balance questions to the kiosk.

**If the network is down**
* The screen says **SAVED OFFLINE**. Carry on as normal; claims are sent automatically when the connection returns.
* The **Queue** badge at the top shows how many are waiting. A red badge means the server refused a claim — tap it, read the reason and tell the manager.
* Offline claims are marked "PIN not verified" for the manager. Use offline mode only when the network really is down.

**When you leave the tablet** tap **🔒 Lock**. It also locks itself after 90 seconds.

---

## Cashier (kiosk tablet)

**Start of shift**: sign in with your own name and PIN. Keep the **Pending claims** tab open; a chime sounds when a claim arrives.

**Approving a claim (every Rewards fill)**
1. When the customer pays, find their claim in **Pending claims** (pump, grade, litres, customer name, card last 4).
2. Compare it with the **Namos till slip**: **pump, grade and litres must match**.
3. Tap **Approve**, type the **Namos receipt / transaction number** from the slip, tap **Approve**.
4. **Reject** if the customer did not pay or left, the litres or card are wrong, or it is a duplicate. Choose the reason.
5. Claims marked **OFFLINE · PIN NOT VERIFIED** need extra care: confirm with the attendant before approving.
6. You cannot decide a claim you captured yourself; another person must do it.
7. Undecided claims expire after 14 hours and earn nothing.

**Paying out cashback**
1. **Pay out** tab → the customer **taps their card** (the card must be present — no card, no payout).
2. Ask the customer to **say** the **last 3 digits of their mobile number**. Do not read them out to the customer.
3. The amount is filled in (the whole balance, or up to a daily limit if the manager has set one). Minimum R20.
4. Optionally type the Namos Paid Out reference, then **Confirm payout** → **Yes, pay out**.
5. The screen shows **PAY R xx,xx CASH FROM TILL**. Pay that exact amount and **record a Paid Out in Namos** for it.

**Customers tab**
* **Register new customer:** tap a new card, enter name and mobile, **read the POPIA consent wording to the customer** and tick the box only if they agree. Hand over the card.
* **Check balance:** tap the card.
* **Replace lost card:** confirm the person's identity, enter their mobile, tap the new card. Old cards are blocked; the balance moves across.
* **Block card:** for a lost, stolen or misused card.

**End of shift**
1. **Shift summary** tab → **Print cash-up list** (or write the lines down).
2. Every payout on the list must match a **Paid Out** in Namos. The total is part of your cash-up.
3. Report any pending claims you know are unpaid, and lock the tablet.

---

## Manager — daily reconciliation checklist

Do this every morning for the **previous day**. Allow 15 minutes.

**1. Journal check (every claim against Namos)**
- [ ] Export the previous day's **Transaction Journal** from Namos as a .txt file.
- [ ] Manager tablet → **Journal check** → choose the file. Check the preview (date, receipts, litres sold), then **Upload and check claims**.
- [ ] Every approved and pending claim is matched to its sale. To pass, the receipt number, pump, grade and litres must be **identical** (not one hundredth of a litre different), and the sale within **30 minutes** of the claim. Split lines on one receipt (same pump) are added together.
- [ ] **RECEIPT NO. WRONG**: the sale was found but the cashier typed the wrong receipt number. Cashback stands; remind the cashier.
- [ ] **MISMATCH**, **NO SALE**, **DUPLICATE**: the claim does not match a sale. The *Why* column says what differs and lists the nearest sales on that pump. Check CCTV or ask the attendant and cashier. If the fill did not happen as claimed, tap **Reverse** and write the reason. Reversals are recorded in the audit log and never happen automatically.
- [ ] Failed **pending** claims: tell the cashier to reject them at the kiosk.
- [ ] Claims just before midnight may match the next day's sales: they are re-checked automatically when the next day's journal is uploaded. Approvals made after the upload: tap **Check again**.
- [ ] *Litres by grade* compares Namos litres sold with approved scheme litres. Investigate a sudden jump in the share on the scheme.

**2. Spot-check approvals** (weekly, or when something looks odd)
- [ ] Export claims CSV, pick approved claims at random, look up each **Namos receipt number** in Namos.
- [ ] Pump, grade, litres and time must match the Namos transaction.

**3. Payouts against Namos Paid Outs**
- [ ] Reports → *By cashier* and the payouts CSV: total paid out per cashier.
- [ ] Must equal the cashback **Paid Outs** in Namos for each cashier's cash-up. Investigate any difference the same day.

**4. Rejected, expired and offline claims**
- [ ] *By day*: rejected and expired counts. Several expired claims suggest claims captured for fills that were never paid.
- [ ] *By attendant*: rows marked **CHECK** (high rejected/expired or offline-unverified claims). Ask the attendant and cashier.
- [ ] Offline claims: confirm the network really was down at those times.

**5. Audit log**
- [ ] Filter **Wrong PIN**: repeated failures on one person may mean someone is guessing a PIN. Reset that PIN.
- [ ] Review **Balance adjusted**, **Rate changed**, **Settings changed**, **Staff saved** and **Device** entries; each should be one you know about.

**Weekly**
- [ ] Dashboard: cashback owed to customers (liability) — make sure the till float can cover typical payouts.
- [ ] Devices: every tablet "last seen" recently; disable any that are missing.
- [ ] Staff: deactivate anyone who has left.

**Monthly**
- [ ] Export last month's claims and payouts CSVs and store them safely (also the accountant's records).
