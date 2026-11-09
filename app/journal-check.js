// Perth Road Rewards — manager "Journal check" tab.
// The manager picks the day's Namos transaction journal (.txt). It is parsed on
// the tablet (journal.js), sent to the server, and every approved or pending
// claim of that day is matched against the sales (rules: migration 006).
import {
  api, h, render, toast, msg, busy, modal, confirmBox, table, downloadCsv,
  money, litres, fmtDate, fmtTime, fmtDateTime, viewGuard,
} from './core.js';
import { parseJournal } from './journal.js';

const RESULT = {
  match: ['ok', 'MATCH'],
  receipt_wrong: ['warn', 'RECEIPT NO. WRONG'],
  mismatch: ['bad', 'MISMATCH'],
  no_sale: ['bad', 'NO SALE'],
  duplicate: ['bad', 'DUPLICATE'],
  unchecked: ['grey', 'NOT CHECKED'],
};
const FAILED = ['mismatch', 'no_sale', 'duplicate'];
const badge = (r) => h('span', { class: `badge ${(RESULT[r] || RESULT.unchecked)[0]}` }, (RESULT[r] || RESULT.unchecked)[1]);
const kpi = (label, value, note) => h('div', { class: 'kpi' }, h('div', { class: 'l' }, label), h('div', { class: 'v' }, value),
  note ? h('div', { class: 'help' }, note) : null);
const call = (fn, params) => api(fn, params).catch((e) => ({ ok: false, message: e.message }));

// ------------------------------------------------------------------ upload + list
export async function journalTab() {
  const stale = viewGuard();
  render(h('h1', {}, 'Journal check'), h('p', { class: 'muted' }, 'Loading…'));
  const r = await call('api_mgr_journal_list');
  if (stale()) return;
  if (!r.ok) { render(h('h1', {}, 'Journal check'), msg(r.message)); return; }
  const done = new Set(r.data.journals.map((j) => j.day));

  const file = h('input', { type: 'file', accept: '.txt,text/plain' });
  const preview = h('div');
  file.onchange = async () => {
    preview.replaceChildren();
    const f = file.files[0];
    if (!f) return;
    let j;
    try { j = parseJournal(await f.text()); } catch (e) { preview.append(msg(`Could not read the file: ${e.message}`)); return; }
    if (!j.rows.length) { preview.append(msg('No fuel sales were found. Choose the Namos transaction journal (.txt).')); return; }
    const btn = h('button', { class: 'go' }, done.has(j.day) ? 'Replace journal and check again' : 'Upload and check claims');
    btn.onclick = () => busy(btn, () => upload(f.name, j, done.has(j.day)));
    preview.append(...[
      h('div', { class: 'kpis' },
        kpi('Journal day', fmtDate(`${j.day}T12:00:00+02:00`)),
        kpi('Receipts', j.receipts, j.reprints ? `${j.reprints} reprinted copies ignored` : null),
        kpi('Fuel sales', j.rows.length, `${fmtTime(j.first_sale)} – ${fmtTime(j.last_sale)}`),
        kpi('Litres sold', litres(j.litres))),
      j.warnings.length ? h('div', { class: 'msg warn' }, h('div', {}, 'Check before uploading:'),
        h('ul', {}, j.warnings.slice(0, 20).map((w) => h('li', { style: 'font-weight:400' }, w)))) : null,
      h('p'),
      h('div', { class: 'row' }, h('span', { class: 'spacer' }), btn)].filter(Boolean));
  };

  render(
    h('div', { class: 'row' }, h('h1', { class: 'grow' }, 'Journal check'), h('button', { class: 'ghost', onclick: journalTab }, 'Refresh')),
    h('p', { class: 'muted' }, 'Upload each day’s Namos transaction journal. Every claim is matched to its sale: receipt number, pump, '
      + 'grade and litres must be identical, and the sale within 30 minutes of the claim.'),
    h('div', { class: 'card' }, h('label', {}, 'Namos transaction journal (.txt)'), file, preview),
    h('h2', {}, 'Checked days'),
    table([
      { label: 'Day', get: (j) => fmtDate(`${j.day}T12:00:00+02:00`) },
      { label: 'Receipts', num: true, get: (j) => j.receipts },
      { label: 'Litres sold', num: true, get: (j) => litres(j.litres) },
      { label: 'Claims', num: true, get: (j) => j.claims },
      { label: 'Passed', num: true, get: (j) => j.passed },
      { label: 'Failed', num: true, get: (j) => j.failed },
      { label: 'To review', get: (j) => (j.open ? h('span', { class: 'badge bad' }, `${j.open} OPEN`) : h('span', { class: 'badge ok' }, 'CLEAR')) },
      { label: 'Uploaded', get: (j) => `${fmtDateTime(j.uploaded_at)} · ${j.uploaded_by || ''}` },
    ], r.data.journals, { onRow: (j) => dayResult(j.day), rowClass: (j) => (j.open ? 'flag' : ''), empty: 'No journals uploaded yet.' }));
}

async function upload(fileName, j, replacing) {
  if (replacing && !(await confirmBox('Replace journal?',
    `A journal for ${fmtDate(`${j.day}T12:00:00+02:00`)} is already uploaded. Replace it and check the claims again? Reversals already made stay.`,
    'Replace', 'primary'))) return;
  const meta = { receipts: j.receipts, litres: j.litres, first_sale: j.first_sale, last_sale: j.last_sale, warnings: j.warnings };
  const sales = j.rows.map((r) => ({
    sold_at: r.sold_at, pos: r.pos, receipt_no: r.receipt_no, pump_no: r.pump_no, grade_code: r.grade_code,
    grade_name: r.grade_name, litres: r.litres, amount_cents: r.amount_cents, lines: r.lines,
    attendant: r.attendant, cashier: r.cashier, shift: r.shift,
  }));
  const r = await api('api_mgr_journal_upload', { p_day: j.day, p_file_name: fileName, p_meta: meta, p_sales: sales });
  if (!r.ok) { toast(r.message, 'bad', 8000); return; }
  toast(`Journal uploaded: ${r.data.sales} fuel sales. Claims checked.`, 'ok');
  dayResult(j.day);
}

// ------------------------------------------------------------------ one day's result
async function dayResult(day) {
  const title = `Journal check · ${fmtDate(`${day}T12:00:00+02:00`)}`;
  const stale = viewGuard();
  render(h('h1', {}, title), h('p', { class: 'muted' }, 'Loading…'));
  const r = await call('api_mgr_journal_result', { p_day: day });
  if (stale()) return;
  if (!r.ok) { render(h('h1', {}, title), msg(r.message)); return; }
  const { journal: jn, grades, claims } = r.data;
  const count = (f) => claims.filter(f).length;
  const open = claims.filter((c) => FAILED.includes(c.result) && c.status === 'approved' && !c.reversed_at);
  const order = { mismatch: 0, no_sale: 0, duplicate: 0, receipt_wrong: 1, unchecked: 2, match: 3 };
  const rows = [...claims].sort((a, b) => (order[a.result] - order[b.result]) || a.captured_at.localeCompare(b.captured_at));

  const recheck = h('button', { class: 'ghost' }, 'Check again');
  recheck.onclick = () => busy(recheck, async () => {
    const x = await api('api_mgr_journal_recheck', { p_day: day });
    if (!x.ok) return toast(x.message, 'bad');
    toast('Claims checked again.', 'ok'); dayResult(day);
  });

  render(
    h('div', { class: 'row' },
      h('button', { class: 'ghost', onclick: journalTab }, '← All days'),
      h('h1', { class: 'grow' }, title), recheck,
      h('button', { class: 'primary', onclick: () => downloadCsv(`journal-check_${day}.csv`, csvCols, rows) }, 'Export CSV')),
    h('p', { class: 'muted' }, `${jn.file_name || 'Journal'} · ${jn.receipts} receipts · ${jn.fuel_rows} fuel sales `
      + `${fmtTime(jn.first_sale)}–${fmtTime(jn.last_sale)} · uploaded ${fmtDateTime(jn.uploaded_at)}`),
    h('div', { class: 'kpis' },
      kpi('Claims checked', claims.length),
      kpi('Matched', count((c) => c.result === 'match')),
      kpi('Receipt no. wrong', count((c) => c.result === 'receipt_wrong'), 'Sale found; cashier typed the wrong number'),
      kpi('Failed', count((c) => FAILED.includes(c.result))),
      kpi('Open to review', open.length, open.length ? `${money(open.reduce((a, c) => a + c.cashback_cents, 0))} cashback` : 'Nothing to do')),
    open.length ? msg(`${open.length} approved claim${open.length > 1 ? 's' : ''} failed the check. Review each one below; `
      + 'reverse the cashback if the fill did not happen as claimed.', 'bad') : null,
    (jn.warnings || []).length ? h('div', { class: 'msg warn' }, 'Journal warnings: ', jn.warnings.join(' ')) : null,
    h('h2', {}, 'Claims'),
    table([
      { label: 'Claimed', get: (c) => fmtTime(c.captured_at) },
      { label: 'Result', get: (c) => h('div', {}, badge(c.result), c.reversed_at ? h('div', {}, h('span', { class: 'badge grey' }, 'REVERSED')) : null) },
      { label: 'Customer', get: (c) => h('div', {}, c.customer, h('div', { class: 'help mono' }, `…${String(c.card).slice(-4)}`)) },
      { label: 'Claim', get: (c) => `P${c.pump} · ${c.grade} · ${litres(c.litres)}` },
      { label: 'Slip', get: (c) => (c.sale ? h('div', {}, `P${c.sale.pump} · ${c.sale.grade} · ${litres(c.sale.litres)}`,
          h('div', { class: 'help' }, `#${c.sale.receipt} at ${fmtTime(c.sale.sold_at)}${c.sale.lines > 1 ? ` · ${c.sale.lines} lines added` : ''}`)) : '—') },
      { label: 'Receipt typed', get: (c) => c.receipt || (c.status === 'pending' ? 'pending' : '—') },
      { label: 'Staff', get: (c) => h('div', {}, `${c.attendant || '?'} → ${c.cashier || '?'}`,
          c.sale ? h('div', { class: 'help' }, `Namos: ${c.sale.attendant || '?'} → ${c.sale.cashier || '?'}`) : null) },
      { label: 'Why', get: (c) => h('div', { style: 'white-space:normal;min-width:220px;font-size:.85rem' }, why(c)) },
      { label: '', get: (c) => action(c, day) },
    ], rows, { rowClass: (c) => (FAILED.includes(c.result) && !c.reversed_at ? 'flag' : ''), empty: 'No claims were captured on this day.' }),
    h('h2', {}, 'Litres by grade'),
    table([
      { label: 'Grade', get: (g) => g.grade },
      { label: 'Sold (Namos)', num: true, get: (g) => litres(g.sold_litres) },
      { label: 'Approved claims', num: true, get: (g) => litres(g.claimed_litres) },
      { label: 'Share on scheme', num: true, get: (g) => (Number(g.sold_litres) ? `${((100 * g.claimed_litres) / g.sold_litres).toFixed(1).replace('.', ',')} %` : '') },
    ], grades));
}

function why(c) {
  const d = c.detail || {};
  const parts = [];
  if (c.result === 'match') parts.push(c.status === 'pending' ? 'Sale found. Claim still pending at the kiosk.' : 'Receipt, pump, grade and litres identical.');
  if (c.result === 'receipt_wrong') parts.push(`Sale #${c.sale?.receipt} matches exactly. ${d.receipt_note || 'The receipt number typed points to a different sale.'}`);
  if (d.differences) parts.push(`Receipt ${c.receipt}: ${d.differences.join('; ')}.`);
  if (d.reason) parts.push(d.reason);
  if (c.result === 'no_sale') {
    if (d.receipt_note) parts.push(d.receipt_note);
    parts.push(`No sale on pump ${c.pump} of ${litres(c.litres)} ${c.grade} within 30 minutes.`);
    if (d.nearby?.length) parts.push(`Nearest on pump ${c.pump}: ${d.nearby.map((n) => `#${n.receipt} ${fmtTime(n.sold_at)} ${n.grade} ${litres(n.litres)}`).join(', ')}.`);
  }
  if (!c.pin_verified) parts.push('Captured offline (PIN not verified).');
  if (c.reversed_at) parts.push(`Reversed ${money(c.reverse_cents)} by ${c.reversed_by || '?'} on ${fmtDateTime(c.reversed_at)}: ${c.reverse_note}`);
  return parts.join(' ');
}

function action(c, day) {
  if (!FAILED.includes(c.result) || c.reversed_at) return '';
  if (c.status !== 'approved') return h('span', { class: 'help' }, 'Reject at the kiosk');
  return h('button', { class: 'small danger', onclick: () => reverse(c, day) }, `Reverse ${money(c.cashback_cents)}`);
}

function reverse(c, day) {
  const note = h('textarea', { rows: 3, placeholder: 'e.g. Checked CCTV: no fill on pump 4 at 10:12. Attendant spoken to.' });
  modal((close) => {
    const go = h('button', { class: 'danger' }, `Reverse ${money(c.cashback_cents)}`);
    go.onclick = () => busy(go, async () => {
      const r = await api('api_mgr_journal_reverse', { p_claim: c.id, p_note: note.value });
      if (!r.ok) return toast(r.message, 'bad');
      close();
      toast(`Cashback reversed. ${c.customer}'s balance is now ${money(r.data.balance_cents)}.`, 'ok', 7000);
      dayResult(day);
    });
    return h('div', {},
      h('h2', {}, 'Reverse cashback'),
      h('p', {}, `${c.customer} · ${fmtDateTime(c.captured_at)} · pump ${c.pump} · ${c.grade} · ${litres(c.litres)}`),
      h('p', {}, why(c)),
      h('p', { class: 'help' }, `This removes ${money(c.cashback_cents)} from the customer's balance. If it was already paid out, `
        + 'the balance goes below zero and is recovered from future cashback. The reversal is recorded in the audit log.'),
      h('label', {}, 'Reason (required)'), note,
      h('div', { class: 'actions' }, h('button', { class: 'ghost', onclick: close }, 'Cancel'), go));
  });
}

const csvCols = [
  { label: 'Claimed', get: (c) => fmtDateTime(c.captured_at) },
  { label: 'Result', get: (c) => (RESULT[c.result] || RESULT.unchecked)[1] },
  { label: 'Claim status', get: (c) => c.status },
  { label: 'Customer', get: (c) => c.customer },
  { label: 'Card', get: (c) => c.card },
  { label: 'Pump', get: (c) => c.pump },
  { label: 'Grade', get: (c) => c.grade },
  { label: 'Litres claimed', get: (c) => c.litres },
  { label: 'Receipt typed', get: (c) => c.receipt },
  { label: 'Slip receipt', get: (c) => c.sale?.receipt },
  { label: 'Slip time', get: (c) => (c.sale ? fmtTime(c.sale.sold_at) : '') },
  { label: 'Slip pump', get: (c) => c.sale?.pump },
  { label: 'Slip grade', get: (c) => c.sale?.grade },
  { label: 'Slip litres', get: (c) => c.sale?.litres },
  { label: 'Attendant', get: (c) => c.attendant },
  { label: 'Cashier', get: (c) => c.cashier },
  { label: 'Namos attendant', get: (c) => c.sale?.attendant },
  { label: 'Cashback R', get: (c) => (c.cashback_cents / 100).toFixed(2) },
  { label: 'Reversed', get: (c) => (c.reversed_at ? fmtDateTime(c.reversed_at) : '') },
  { label: 'Detail', get: (c) => why(c) },
];
