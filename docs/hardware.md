# Perth Road Rewards — Hardware List

Prices were checked by web search on **2 November 2026**. They come from South African price-comparison sites and retailers and change often; confirm before buying. Where no rand price could be found, an estimate is given and marked **(est.)**, using roughly R18/US$ and R20/€ plus shipping.

---

## 1. Important: the tablet must really have NFC

Web NFC needs an Android device with a built-in NFC chip, running Chrome. **Many popular tablets do not have NFC** — including the **Samsung Galaxy Tab A9 / A9+**, which several sources confirm lacks NFC. Check the specification sheet for "NFC: Yes" before buying, and test one card in the shop if possible.

## 2. Recommended set-up

| # | Item | Use | Approx. price (ZAR) | Notes |
|---|---|---|---|---|
| 1 | **Rugged Android tablet with NFC**, e.g. Samsung Galaxy Tab Active5 (IP68, NFC, glove mode) | Forecourt | ~R7 900 (aggregator, dated Jan 2024) | Built for outdoor use; replaceable battery; bright screen. Best choice for the forecourt. |
| 1-alt | **Budget option:** Android phone with NFC in a rugged case, e.g. Samsung Galaxy A16 (confirm the SA model lists NFC) | Forecourt | R2 600 – R3 300 (4G); ~R4 500 (5G) | Smaller screen but cheap and NFC-capable; phones almost always have NFC. |
| 1-alt | Other rugged NFC tablets (e.g. Oukitel RT-series, Ruggex RT8) | Forecourt | Price not published at time of writing | Oukitel South Africa lists NFC on the RT3; confirm Android version is recent enough for current Chrome. |
| 2 | **Kiosk tablet** — any Android tablet with NFC, *or* a Galaxy Tab A9+ **plus** a USB card reader (item 5) | Kiosk | Tab A9+: R3 000 – R5 000 | Indoors, so a standard tablet is fine. |
| 3 | **Rugged case** with kickstand/hand strap | Both tablets | ~R850 – R900 (Rugged SA, Tab A9/A9+) | Match the case to the exact tablet model. |
| 4 | **Mounts**: lockable wall/desk tablet mount for the kiosk; lanyard or hand strap for the forecourt | Both | R300 – R1 000 (est.) | A security cable reduces theft at the kiosk. |
| 5 | **USB keyboard-emulation NFC reader**, 13.56 MHz, reads NTAG, outputs **hex UID + Enter** (optional) | Kiosk | R250 – R600 imported (est.; Olimex lists €10.95–€19.95); local ZKTeco CR20M ~R985 – R1 110 (check it does keyboard output) | Needs a USB-C OTG adapter (~R100). **Do not buy the ACR122U** for this: it needs a driver and does not type the UID on Android. |
| 6 | **NFC cards — NTAG215 or NTAG216**, white PVC, ISO card size, printed with "Perth Road Rewards" and a card number | Customers | Blank: about R30 – R40 per 5 (Shein ZA, chip not stated) or ~US$20 per 10 (Elechouse, NTAG215 selectable); printed custom cards: R10 – R25 each in runs of 250+ (est.) | NTAG cards work with Web NFC on every NFC Android device. **Avoid MIFARE Classic**: many tablets cannot read it. |
| 7 | **Wi-Fi coverage on the forecourt**: outdoor access point or mesh node | Forecourt | R1 000 – R3 000 (est.) | The app works offline but claims sync only when connected. |
| 8 | Chargers and spare cables; a power bank for load-shedding | Both | R300 – R800 (est.) | The forecourt tablet should be charged between shifts. |

**Indicative total** for one forecourt and one kiosk device, cases, mounts and 250 printed cards: roughly **R14 000 – R20 000** with the rugged tablet, or **R9 000 – R13 000** with the budget phone option.

## 3. Card specification for the printer

* Chip: **NXP NTAG215** (or NTAG216), 13.56 MHz, ISO/IEC 14443-A, 7-byte UID.
* Size: ISO CR80, 85.6 × 54 × 0.8 mm, white PVC.
* Pre-formatted NDEF (most suppliers ship them this way); no data needs to be written — only the UID is used.
* Print: scheme name "Perth Road Rewards", short terms ("Cashback paid in cash at the kiosk. Minimum R50."), and a **card number** printed on the back — print the card's UID so cashiers can type it if a card will not read.
* Do **not** use TotalEnergies branding (owner's decision).
* Order a sample of 10 first and test them on the actual forecourt tablet before the full run.

## 4. Sources (checked 2 November 2026)

* Galaxy Tab A9+ prices — PriceCheck: <https://www.pricecheck.co.za/offers/251799008/Samsung+Galaxy+Tab+A9%2B>, <https://www.pricecheck.co.za/offers/251412141/Samsung+Galaxy+Tab+A9%2B+11%22+5G+4+64GB+Gray+SM-X216BZAAAFA>
* Galaxy Tab A9+ has no NFC — NanoReview: <https://nanoreview.net/en/tablet/samsung-galaxy-tab-a9-plus>; Digital Citizen review: <https://www.digitalcitizen.life/samsung-galaxy-tab-a9-plus-review/>; Samsung Community: <https://eu.community.samsung.com/t5/tablets/nfc-galax-tab-a9/m-p/11949180>
* Galaxy Tab Active5 price — AssuredZone: <https://www.assuredzone.com/za/samsung-galaxy-tab-active-5-price-in-south-africa/>
* Galaxy A16 prices — PriceCheck: <https://www.pricecheck.co.za/offers/253648668/Samsung+Galaxy+A16+LTE+128GB>, <https://www.pricecheck.co.za/offers/258012312/Samsung+Galaxy+A16+4G+4GB+128GB+%E2%80%93+Green>; AssuredZone: <https://www.assuredzone.com/za/samsung-galaxy-a16-5g-price-in-south-africa/>
* Rugged cases — Rugged SA: <https://ruggedsa.co.za/product/samsung-galaxy-tab-a9-plus-rugged-cover/>
* Rugged NFC tablets — Rugged SA: <https://ruggedsa.co.za/product/ruggex-rt8-rugged-tablet-android-9-8-screen/>; Oukitel SA: <https://www.oukitel.co.za/>
* USB readers — Olimex: <https://olimex.com/Products/Modules/RFID>; PriceCheck (ZKTeco CR20M): <https://www.pricecheck.co.za/offers/253814924/CR20M+Take-on+Reader+-+Mifare+13.56MHZ+-+USB>
* NFC cards — Shein ZA: <https://m.shein.com/za/Access-Cards-c-5580.html>; Elechouse: <https://www.elechouse.com/product/n8654-13-56mhz-white-pvc-nfc-cards-10pcs/>
