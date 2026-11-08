# Perth Road Rewards — Set-up Guide

Follow these steps in order. Allow about two hours, including testing with a real card.

---

## 1. Publish the app (GitHub Pages)

The app is a set of static files in the `app/` folder. GitHub hosts it free of charge over HTTPS, which the card reader requires.

### 1.1 First publication with GitHub Desktop

1. Open **GitHub Desktop** → **File → Add local repository…** → choose the `perth-road-rewards` folder.
   (The folder is already a Git repository with the first commit made.)
2. Click **Publish repository**. Name: `perth-road-rewards`. You may tick **Keep this code private** if your GitHub plan allows Pages on private repositories; otherwise leave it public — the repository contains no secrets (see §7).
3. In a browser, open the repository on github.com → **Settings → Pages**.
   Under **Build and deployment → Source**, choose **GitHub Actions**.
4. Open the **Actions** tab. The workflow **Publish app to GitHub Pages** runs on every push. If it has not run yet, open it and click **Run workflow**.
5. When it finishes (about one minute), the app is live at:
   `https://<your-github-username>.github.io/perth-road-rewards/`

Write this address down; every tablet uses it.

### 1.2 Publishing later changes

Make the change, then in GitHub Desktop: write a summary → **Commit to main** → **Push origin**. The site updates within a couple of minutes. Tablets pick up the new version the next time the app is opened with a connection.

### 1.3 Alternative: Netlify Drop

Go to `https://app.netlify.com/drop` and drag the **`app` folder** (not the whole project) onto the page. Netlify gives an HTTPS address. Re-drag the folder to publish changes. Use one host only, so every tablet uses the same address.

---

## 2. First-run manager set-up

Do this on the device the manager will use most (phone or laptop), with Chrome.

1. Open the app address.
2. The app shows **First-time set-up** because no staff exist yet.
3. Enter your name, a **6-digit PIN** (twice) and a name for this device, e.g. "Manager phone".
4. Tap **Set up as manager**. This device is now the manager device and you are signed in.

> Remember the PIN. There is no self-service reset for the only manager. Create a second manager account (§3) as a back-up.

On a phone, use Chrome's menu → **Add to Home screen / Install app** so it opens like an app.

---

## 3. Add staff

Manager device → **Staff → Add staff member**.

| Role | Can sign in on | Can do |
|---|---|---|
| Attendant | Forecourt tablet | Capture claims |
| Cashier | Kiosk tablet | Approve/reject claims, pay out, register customers, replace/block cards, shift summary |
| Manager | Any tablet | Everything |

* Give each person their **own** 4–6 digit PIN and tell them privately.
* To reset a forgotten PIN or unlock someone after 5 wrong PINs: tap the person → enter a new PIN → **Save**.
* When someone leaves, untick **Active**. Do not delete; their history stays in the reports.

---

## 4. Review settings and rates

* **Settings:** scheme name, R50 minimum payout, R1 000 daily payout limit, 150 L default cap, 200 L per fill, 14-hour claim expiry.
* **Pumps (fixed, view only):** the 10 pumps and their grades are installed with the system (migration 009, from the Namos journal of 1 Nov 2026): ULP 95 on pumps 1, 4, 8, 9; ULP 93 on pump 6; D50 on pumps 2, 3, 5, 7, 10 (pump 7 corrected to D50 by migration 010). The forecourt asks only for the pump; the grade fills in by itself, and the server refuses a claim whose grade the pump does not sell. A physical change to the forecourt needs a new migration.
* **Rates:** 10 c/L on all grades to start. Changes apply to claims captured from that moment.

---

## 5. Pair each tablet

For each tablet:

1. Manager device → **Devices → Add device**. Give it a clear name ("Forecourt 1", "Kiosk") and choose the type.
2. A large **8-character pairing code** appears. It works **once** and expires in **24 hours**.
3. On the tablet, open the app address in Chrome. It shows **Pair this tablet**. Type the code → **Pair this tablet**.
4. The tablet now shows the staff who may sign in on it.

If a tablet is lost or stolen: **Devices → Disable** immediately. To move a tablet to a new device or recover a broken one: **Re-pair** (the old pairing stops working) and enter the new code on the replacement.

---

## 6. Android tablet set-up (forecourt and kiosk)

Do these once per tablet.

### 6.1 Basics

1. Update Android and **Google Chrome** to the latest versions (Play Store).
2. **Settings → Connections → NFC** (or *Connected devices → Connection preferences → NFC*): **On**.
3. Connect to the site **Wi-Fi**. Check signal at every pump island on the forecourt (§8 of the hardware list).
4. **Settings → Display → Screen timeout:** the longest option.
5. **Settings → Developer options → Stay awake** (screen never sleeps while charging):
   enable Developer options by tapping **Settings → About tablet → Software information → Build number** seven times, then turn on **Stay awake**.
6. Set the date, time and time zone to automatic (Johannesburg). Claim times come from the tablet.

### 6.2 Install the app

1. Open the app address in Chrome.
2. Chrome menu (⋮) → **Install app** (or **Add to Home screen**).
3. Open it from the home screen icon. It runs full-screen.
4. Pair it (§5).

### 6.3 Start the card reader

On the first card screen, tap **Start card reader** and allow NFC access when Chrome asks. Chrome remembers the permission; on later starts the reader usually turns on by itself. If the button appears again, tap it once.

**Where to tap:** the NFC antenna is usually in the middle of the back of the tablet. Mark the spot on the rugged case with a sticker.

### 6.4 Lock the tablet to the app (recommended)

Choose one:

* **Screen pinning (built in, free).** Settings → Security (or Biometrics and security) → Other security settings → **Pin windows / App pinning**: On, with "Ask for PIN before unpinning". Open the app → Recent apps button → tap the app icon → **Pin this app**. Staff then cannot leave the app without the device PIN.
* **Kiosk launcher.** A kiosk/MDM app (for example Fully Kiosk Browser, or Samsung Knox on Samsung devices) can lock the tablet to the app address and restart it after a power cut. Configure it to open the app address in Chrome mode so Web NFC keeps working; test card reading after setting it up.

### 6.5 Kiosk with a USB card reader (optional)

If the kiosk tablet has no NFC, or a desk reader is preferred:

1. Use a USB **keyboard-emulation (HID)** 13.56 MHz reader that reads NTAG cards (see hardware list). Connect with a USB-C OTG adapter.
2. **Configure it to output the card UID in hexadecimal, in normal byte order, followed by Enter.** Many readers default to a 10-digit decimal number, which will not match the hexadecimal ID that the NFC tablets read.
3. **Cross-check before go-live:** register a test card on the kiosk with the USB reader, then tap the same card on the forecourt tablet. The forecourt must show the customer's name. If it says "card not registered", the reader's output format is wrong. (Then block the test card, or ask the administrator to remove the test customer.)

---

## 7. Supabase notes

* **Project:** `perth-road-rewards`, region eu-west-2 (London), ref `ospxqraxdraykoutmbmg`. Dashboard: `https://supabase.com/dashboard/project/ospxqraxdraykoutmbmg`.
* **Keys:** the app contains only the *publishable* key, which is designed to be public. Never put the *secret* (service-role) key, the database password, staff PINs or device tokens in the repository.
* **Free-tier pausing:** a free project is **paused after about one week with no activity**. Normal daily use keeps it active. If the site closes for a week or more, open the Supabase dashboard afterwards and click **Restore project** if it was paused; it takes a few minutes.
* **Limits:** the free tier (500 MB database) is far larger than this scheme needs for many years.
* **Backups:** the free tier keeps only limited automatic backups and has no point-in-time recovery. Once a month, and before any database change:
  * Manager app → **Reports** → last 30 days → **Export claims CSV** and **Export payouts CSV**, and store the files safely (e.g. Google Drive); and
  * optionally, Supabase dashboard → **Database → Backups** to check the latest backup, or ask the administrator to take a full `pg_dump`.
  * For full protection, the Supabase Pro plan adds daily backups with 7-day retention.
* **Database changes** are kept in `supabase/migrations/`. Never edit an applied migration; add a new numbered file.

---

## 8. Go-live checklist

- [ ] App published and opens over HTTPS on every device.
- [ ] Manager account created; second manager added as back-up.
- [ ] Settings checked, Pumps tab matches the forecourt, rates set.
- [ ] All staff added with personal PINs.
- [ ] Forecourt and kiosk tablets paired, installed, NFC on, stay-awake on, pinned.
- [ ] One real card registered, a claim captured on the forecourt, approved on the kiosk with a real Namos receipt number, and visible in Reports.
- [ ] Wi-Fi coverage tested at every pump island.
- [ ] Staff trained with `staff-procedures.md`.
- [ ] Accountant consulted on the tax treatment of cash payouts (design document §11).
- [ ] Test customers and cards removed or blocked before customers are signed up.
