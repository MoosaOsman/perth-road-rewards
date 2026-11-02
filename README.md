# Perth Road Rewards

Fuel cashback loyalty scheme for TotalEnergies Perth Road, Johannesburg. Runs entirely separately from the Wayne pumps and the Namos POS.

* **`app/`** — the tablet app (static PWA, no build step). Published to GitHub Pages by `.github/workflows/pages.yml`.
* **`supabase/migrations/`** — database schema and API functions, `001`–`005`, all applied to Supabase project `ospxqraxdraykoutmbmg`. Never edit an applied migration; add a new numbered file.
* **`supabase/tests/test_scenarios.sql`** — 60-check scenario test. Run only on an **empty** database, then wipe.
* **`docs/`**
  * [design.md](docs/design.md) — architecture, rules, judgement calls, fraud model, POPIA, tax note
  * [setup-guide.md](docs/setup-guide.md) — hosting, first-run set-up, staff, pairing, Android tablets, Supabase notes
  * [hardware.md](docs/hardware.md) — what to buy, with prices
  * [staff-procedures.md](docs/staff-procedures.md) — attendant, cashier and manager daily reconciliation
* **`HANDOFF.md`** — original build brief.

## Local preview

```bash
cd app && python3 -m http.server 8765
```

Open <http://localhost:8765>. Web NFC needs HTTPS on Android, so use manual card entry locally.
