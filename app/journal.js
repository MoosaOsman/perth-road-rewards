// Perth Road Rewards — Namos transaction journal parser.
// Turns the POS "Transaction Journal" text export into one row per receipt,
// pump and grade. No DOM access, so it also runs under Node for testing.
//
// Journal layout: each receipt is a block of lines followed by its footer
//   Date     Time  Num   POS CNo Shift
//   26/11/01 02:55 00188 02 2173  545        (date is YY/MM/DD, local time)
// Fuel lines inside a block:
//        35.48 litre Pump # 10
//   Excellium D50            R     1341.50 B
// Balancing reports, paid-outs and shift messages have no fuel lines and are ignored.
// Account receipts are printed more than once (customer copies): identical
// reprints share date, time, receipt number and POS and are counted once.

const FOOTER_HEAD = /^Date\s+Time\s+Num\s+POS\s+CNo\s+Shift\s*$/;
const FOOTER = /^(\d{2})\/(\d{2})\/(\d{2})\s+(\d{2}):(\d{2})\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$/;
const FUEL = /^\s*(-?\d+(?:\.\d+)?)\s+litre\s+Pump\s*#\s*(\d+)\s*$/i;
const AMOUNT = /^(.*?)\s+R\s+(-?[\d ]+\.\d{2})(-)?\s*[A-Z]?\s*$/;

// Namos product names → app grade codes (fuel_grades.code).
const GRADES = [
  [/ULP\s*93/i, 'ULP93'],
  [/ULP\s*95/i, 'ULP95'],
  [/D\s*500\b/i, 'D500'],
  [/D\s*50\b/i, 'D50'],
];
export function gradeCode(name) {
  for (const [re, code] of GRADES) if (re.test(name)) return code;
  return null;
}

// Receipt numbers as typed by cashiers vary ("00188", "188", "Rec 188"):
// compare digits only, without leading zeros.
export const receiptKey = (s) => String(s || '').replace(/\D/g, '').replace(/^0+(?=\d)/, '');

const cents = (s) => Math.round(parseFloat(String(s).replace(/\s/g, '')) * 100);
const r2 = (n) => Math.round(n * 100) / 100;

export function parseJournal(text) {
  const lines = String(text).replace(/\r/g, '').split('\n');
  const seen = new Map();          // reprint key → block signature
  const rows = [];
  const warnings = [];
  let block = [];
  let reprints = 0, receipts = 0, refunds = 0;

  for (let i = 0; i < lines.length; i++) {
    if (!FOOTER_HEAD.test(lines[i])) { block.push(lines[i]); continue; }
    const m = FOOTER.exec(lines[i + 1] || '');
    const body = block;
    block = [];
    if (!m) { i++; continue; }      // footer without a receipt number (reports)
    i++;
    const [, yy, mo, dd, hh, mi, num, pos, cno, shift] = m;
    const fuel = readFuel(body);
    if (!fuel.lines.length) continue;

    const key = `${yy}${mo}${dd}${hh}${mi}|${num}|${pos}`;
    const sig = fuel.lines.map((l) => `${l.pump}/${l.name}/${l.litres}`).join(';');
    if (seen.has(key)) {
      reprints++;
      if (seen.get(key) !== sig) warnings.push(`Receipt ${num} at ${hh}:${mi} appears twice with different fuel lines; the first copy was used.`);
      continue;
    }
    seen.set(key, sig);
    receipts++;
    if (fuel.refund) { refunds++; warnings.push(`Receipt ${num} at ${hh}:${mi} is a refund or negative sale and was not used for matching.`); continue; }

    const date = `20${yy}-${mo}-${dd}`;
    const soldAt = `${date}T${hh}:${mi}:00+02:00`;
    // One row per pump and grade: split lines on the same pump are added up.
    const groups = new Map();
    for (const l of fuel.lines) {
      const g = `${l.pump}|${l.name}`;
      const cur = groups.get(g) || { litres: 0, amount: 0, lines: 0 };
      cur.litres += l.litres; cur.amount += l.amount; cur.lines += 1;
      groups.set(g, cur);
    }
    for (const [g, v] of groups) {
      const [pump, name] = g.split('|');
      const code = gradeCode(name);
      if (!code) warnings.push(`Receipt ${num}: unknown fuel product "${name}".`);
      rows.push({
        date, sold_at: soldAt, receipt_no: num, receipt_key: receiptKey(num), pos, cashier_no: cno, shift,
        pump_no: Number(pump), grade_name: name, grade_code: code,
        litres: r2(v.litres), amount_cents: v.amount, lines: v.lines,
        attendant: fuel.attendant, cashier: fuel.cashier,
      });
    }
  }

  // Business day = the date most receipts carry.
  const byDate = {};
  rows.forEach((r) => { byDate[r.date] = (byDate[r.date] || 0) + 1; });
  const day = Object.entries(byDate).sort((a, b) => b[1] - a[1])[0]?.[0] || null;
  const times = rows.map((r) => r.sold_at).sort();
  return {
    day, rows, warnings, reprints, refunds,
    receipts,
    first_sale: times[0] || null,
    last_sale: times[times.length - 1] || null,
    litres: r2(rows.reduce((a, r) => a + r.litres, 0)),
  };
}

function readFuel(body) {
  const out = { lines: [], attendant: null, cashier: null, refund: false };
  for (let j = 0; j < body.length; j++) {
    const f = FUEL.exec(body[j]);
    if (f) {
      // the product line is the next non-empty line
      let k = j + 1;
      while (k < body.length && !body[k].trim()) k++;
      const a = AMOUNT.exec(body[k] || '');
      const litres = parseFloat(f[1]);
      const amount = a ? cents(a[2]) * (a[3] ? -1 : 1) : 0;
      if (litres < 0 || amount < 0) out.refund = true;
      out.lines.push({ pump: Number(f[2]), litres, name: a ? a[1].trim() : (body[k] || '').trim(), amount });
      j = k;
      continue;
    }
    const t = body[j].trim();
    if (t === 'Attendant:') out.attendant = (body[j + 1] || '').trim() || null;
    else if (t === 'Cashier:') out.cashier = (body[j + 1] || '').trim() || null;
    else if (/refund/i.test(t)) out.refund = true;
  }
  return out;
}
