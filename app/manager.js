// Perth Road Rewards — manager mode.
import {
  S, api, h, render, toast, msg, busy, modal, confirmBox, table, downloadCsv,
  money, litres, rate, parseRands, centsToInput, fmtDate, fmtTime, fmtDateTime, todayLocal,
} from './core.js';
import { frame, setTabs, paintStatus, refreshBoot } from './app.js';
import { pendingTab, payoutTab, customerDesk, startPolling } from './kiosk.js';

export function start() {
  frame.statusExtras = [];
  paintStatus();
  setTabs([
    { id: 'dash', label: 'Dashboard', render: dashboardTab },
    { id: 'pending', label: 'Pending claims', render: pendingTab },
    { id: 'payout', label: 'Pay out', render: payoutTab },
    { id: 'customers', label: 'Customers', render: customersTab },
    { id: 'rates', label: 'Rates', render: ratesTab },
    { id: 'settings', label: 'Settings', render: settingsTab },
    { id: 'staff', label: 'Staff', render: staffTab },
    { id: 'devices', label: 'Devices', render: devicesTab },
    { id: 'reports', label: 'Reports', render: reportsTab },
    { id: 'audit', label: 'Audit log', render: auditTab },
  ]);
  startPolling();
}

const kpi = (label, value, note) => h('div', { class: 'kpi' }, h('div', { class: 'l' }, label), h('div', { class: 'v' }, value),
  note ? h('div', { class: 'help' }, note) : null);

async function load(title, fn, params) {
  render(h('h1', {}, title), h('p', { class: 'muted' }, 'Loading…'));
  const r = await api(fn, params).catch((e) => ({ ok: false, message: e.message }));
  if (!r.ok) { render(h('h1', {}, title), msg(r.message)); return null; }
  return r.data;
}

// Attendant review flags (judgement call, see design doc §Fraud model):
// rejected + expired ≥ 20 % of claims (with at least 5 claims), or any offline-unverified claim.
function attendantFlag(a) {
  const bad = Number(a.rejected) + Number(a.expired);
  return (a.claims >= 5 && bad / a.claims >= 0.2) || Number(a.offline_unverified) > 0;
}
const attendantCols = [
  { label: 'Attendant', get: (a) => a.name },
  { label: 'Claims', num: true, get: (a) => a.claims },
  { label: 'Approved', num: true, get: (a) => a.approved },
  { label: 'Rejected', num: true, get: (a) => a.rejected },
  { label: 'Expired', num: true, get: (a) => a.expired },
  { label: 'Offline unverified', num: true, get: (a) => a.offline_unverified },
  { label: 'Approved litres', num: true, get: (a) => litres(a.approved_litres) },
  { label: 'Review', get: (a) => (attendantFlag(a) ? h('span', { class: 'badge warn' }, 'CHECK') : '') },
];

// ------------------------------------------------------------------ dashboard
async function dashboardTab() {
  const d = await load('Dashboard', 'api_mgr_dashboard');
  if (!d) return;
  render(
    h('div', { class: 'row' }, h('h1', { class: 'grow' }, 'Dashboard'), h('button', { class: 'ghost', onclick: dashboardTab }, 'Refresh')),
    h('div', { class: 'kpis' },
      kpi('Cashback owed to customers', money(d.liability_cents), 'Total of all balances'),
      kpi('Customers', d.customers),
      kpi('Active cards', d.active_cards),
      kpi('Pending claims', d.pending)),
    h('h2', {}, 'Last 7 days (approved claims by fill date)'),
    table([
      { label: 'Day', get: (x) => fmtDate(x.day) },
      { label: 'Approved', num: true, get: (x) => x.approved },
      { label: 'Litres', num: true, get: (x) => litres(x.litres) },
      { label: 'Cashback earned', num: true, get: (x) => money(x.earned_cents) },
      { label: 'Rejected', num: true, get: (x) => x.rejected },
      { label: 'Expired', num: true, get: (x) => x.expired },
      { label: 'Paid out', num: true, get: (x) => money(x.payout_cents) },
    ], d.days),
    h('h2', {}, 'Attendants (last 7 days)'),
    h('p', { class: 'muted' }, 'CHECK = rejected + expired is 20 % or more of 5+ claims, or the attendant has offline (PIN-unverified) claims.'),
    table(attendantCols, d.attendants, { rowClass: (a) => (attendantFlag(a) ? 'flag' : ''), empty: 'No claims in the last 7 days.' }));
}

// ------------------------------------------------------------------ rates
async function ratesTab() {
  const hist = await load('Rates', 'api_mgr_rates_history');
  if (!hist) return;
  await refreshBoot();
  const grades = S.boot.grades;
  const all = h('input', { inputmode: 'decimal', placeholder: 'c/L', style: 'max-width:160px' });
  const setRate = async (btn, grade, input) => busy(btn, async () => {
    const v = Number(String(input.value).replace(',', '.'));
    if (!input.value || Number.isNaN(v)) return toast('Enter cents per litre.', 'bad');
    const label = grade ? grade : 'ALL grades';
    if (!await confirmBox('Change rate', `Set ${label} to ${rate(v)}? Claims already captured keep their old rate.`, 'Set rate')) return;
    const r = await api('api_mgr_set_rate', { p_grade: grade, p_cents: v });
    if (!r.ok) return toast(r.message, 'bad');
    toast('Rate updated.', 'ok');
    ratesTab();
  });
  const allBtn = h('button', { class: 'primary' }, 'Set all grades');
  allBtn.onclick = () => setRate(allBtn, null, all);
  render(
    h('h1', {}, 'Earn rates'),
    h('p', { class: 'muted' }, 'Cashback in cents per litre. A change applies to claims captured from now on.'),
    h('div', { class: 'card row' }, h('b', {}, 'All grades:'), all, allBtn),
    h('div', { class: 'grid two' }, grades.map((g) => {
      const inp = h('input', { inputmode: 'decimal', value: g.rate, style: 'max-width:140px' });
      const b = h('button', { class: 'go' }, 'Set');
      b.onclick = () => setRate(b, g.code, inp);
      return h('div', { class: 'card' }, h('h3', {}, `${g.name} (${g.code})`),
        h('p', { class: 'big' }, `Now: ${rate(g.rate)}`), h('div', { class: 'row' }, inp, h('span', {}, 'c/L'), b));
    })),
    h('h2', {}, 'History'),
    table([
      { label: 'From', get: (x) => fmtDateTime(x.from) },
      { label: 'Grade', get: (x) => x.grade },
      { label: 'Rate', num: true, get: (x) => rate(x.cents_per_litre) },
      { label: 'Set by', get: (x) => x.by || 'Initial' },
    ], hist.history));
}

// ------------------------------------------------------------------ settings
async function settingsTab() {
  await refreshBoot();
  const s = S.boot.settings;
  const f = {
    scheme_name: h('input', { value: s.scheme_name }),
    min_payout: h('input', { inputmode: 'decimal', value: centsToInput(s.min_payout_cents) }),
    max_payout_day: h('input', { inputmode: 'decimal', value: centsToInput(s.max_payout_day_cents) }),
    default_cap_litres: h('input', { inputmode: 'decimal', value: s.default_cap_litres }),
    max_litres_per_fill: h('input', { inputmode: 'decimal', value: s.max_litres_per_fill }),
    claim_expiry_hours: h('input', { inputmode: 'numeric', value: s.claim_expiry_hours }),
    pump_count: h('input', { inputmode: 'numeric', value: s.pump_count }),
  };
  const out = h('div');
  const save = h('button', { class: 'primary block', type: 'submit' }, 'Save settings');
  const field = (label, el, help) => [h('label', {}, label), el, help ? h('div', { class: 'help' }, help) : null];
  render(h('h1', {}, 'Settings'), h('form', { class: 'card narrow', onsubmit: (e) => { e.preventDefault(); submit(); } },
    field('Scheme name', f.scheme_name, 'Shown in the header on every tablet.'),
    field('Minimum payout (R)', f.min_payout),
    field('Maximum payout per customer per day (R)', f.max_payout_day),
    field('Default daily litre cap per card', f.default_cap_litres, 'Can be raised per customer (taxis, fleets).'),
    field('Maximum litres in one fill', f.max_litres_per_fill),
    field('Unapproved claims expire after (hours, 1–72)', f.claim_expiry_hours),
    field('Number of pumps (1–40)', f.pump_count),
    h('p'), out, save));
  const submit = () => busy(save, async () => {
    out.replaceChildren();
    const min = parseRands(f.min_payout.value), max = parseRands(f.max_payout_day.value);
    if (min == null || max == null) return out.append(msg('Enter the rand amounts as numbers, e.g. 50,00.'));
    const r = await api('api_mgr_update_settings', { p_settings: {
      scheme_name: f.scheme_name.value, min_payout_cents: min, max_payout_day_cents: max,
      default_cap_litres: Number(f.default_cap_litres.value.replace(',', '.')),
      max_litres_per_fill: Number(f.max_litres_per_fill.value.replace(',', '.')),
      claim_expiry_hours: parseInt(f.claim_expiry_hours.value, 10),
      pump_count: parseInt(f.pump_count.value, 10),
    } });
    if (!r.ok) return out.append(msg(r.message));
    await refreshBoot();
    out.append(msg('Settings saved. Other tablets pick them up at their next sign-in.', 'ok'));
  });
}

// ------------------------------------------------------------------ staff
async function staffTab() {
  const d = await load('Staff', 'api_mgr_staff_list');
  if (!d) return;
  render(
    h('div', { class: 'row' }, h('h1', { class: 'grow' }, 'Staff'), h('button', { class: 'primary', onclick: () => staffForm(null) }, 'Add staff member')),
    h('p', { class: 'muted' }, 'Tap a person to edit, reset their PIN (this also unlocks them) or deactivate them.'),
    table([
      { label: 'Name', get: (s) => s.name },
      { label: 'Role', get: (s) => s.role },
      { label: 'Status', get: (s) => [s.active ? h('span', { class: 'badge ok' }, 'Active') : h('span', { class: 'badge grey' }, 'Inactive'),
        s.locked ? [' ', h('span', { class: 'badge bad' }, 'LOCKED')] : null] },
      { label: 'Added', get: (s) => fmtDate(s.created_at) },
    ], d.staff, { onRow: staffForm }));
}

function staffForm(s) {
  modal((close) => {
    const name = h('input', { value: s ? s.name : '' });
    const role = h('select', {}, ['attendant', 'cashier', 'manager'].map((r) => h('option', { value: r, selected: s && s.role === r }, r)));
    const active = h('input', { type: 'checkbox', checked: s ? s.active : true });
    const pin = h('input', { type: 'password', inputmode: 'numeric', maxlength: 6, autocomplete: 'new-password' });
    const pin2 = h('input', { type: 'password', inputmode: 'numeric', maxlength: 6, autocomplete: 'new-password' });
    const out = h('div');
    const ok = h('button', { class: 'go', type: 'submit' }, 'Save');
    const submit = () => busy(ok, async () => {
      out.replaceChildren();
      if (pin.value !== pin2.value) return out.append(msg('The two PINs do not match.'));
      const r = await api('api_mgr_staff_save', { p_id: s ? s.id : null, p_name: name.value, p_role: role.value,
        p_new_pin: pin.value || null, p_active: active.checked });
      if (!r.ok) return out.append(msg(r.message));
      close(); toast('Saved.', 'ok'); staffTab();
    });
    return h('form', { onsubmit: (e) => { e.preventDefault(); submit(); } },
      h('h2', {}, s ? `Edit ${s.name}` : 'Add staff member'),
      s && s.locked ? msg('Locked after too many wrong PINs. Set a new PIN to unlock.', 'warn') : null,
      h('label', {}, 'Name'), name,
      h('label', {}, 'Role'), role,
      h('div', { class: 'help' }, 'Attendant: forecourt tablet. Cashier: kiosk tablet. Manager: everything.'),
      h('label', {}, s ? 'New PIN (leave blank to keep)' : 'PIN (4–6 digits)'), pin,
      h('label', {}, 'PIN again'), pin2,
      h('label', { class: 'check' }, active, h('span', {}, 'Active (can sign in)')),
      out, h('div', { class: 'actions' }, h('button', { type: 'button', class: 'ghost', onclick: close }, 'Cancel'), ok));
  });
}

// ------------------------------------------------------------------ devices
async function devicesTab() {
  const d = await load('Devices', 'api_mgr_devices');
  if (!d) return;
  const act = async (dev, action, label) => {
    if (!await confirmBox(label, action === 'repair'
      ? `Issue a new pairing code for “${dev.name}”? The tablet stops working until it is paired again.`
      : `${label} “${dev.name}”?`, label, action === 'disable' ? 'danger' : 'go')) return;
    const r = await api('api_mgr_device_action', { p_id: dev.id, p_action: action });
    if (!r.ok) return toast(r.message, 'bad');
    if (r.data.pairing_code) showCode(dev.name, r.data.pairing_code);
    devicesTab();
  };
  render(
    h('div', { class: 'row' }, h('h1', { class: 'grow' }, 'Devices'), h('button', { class: 'primary', onclick: addDevice }, 'Add device')),
    h('p', { class: 'muted' }, 'Each tablet is paired once with a single-use code valid for 24 hours. Disable a lost or stolen tablet immediately.'),
    h('div', { class: 'stack' }, d.devices.map((x) => h('div', { class: 'card row' },
      h('div', { class: 'grow' },
        h('b', {}, x.name), ` · ${x.kind}`, x.this_device ? h('span', { class: 'badge ok' }, ' THIS DEVICE') : null,
        h('div', { class: 'muted' }, x.paired ? `Last seen ${x.last_seen ? fmtDateTime(x.last_seen) : 'never'}` : 'Not paired yet'),
        x.pairing_code ? h('div', {}, 'Pairing code ', h('b', { class: 'mono' }, x.pairing_code), ` (until ${fmtDateTime(x.pairing_expires)})`) : null,
        !x.active ? h('span', { class: 'badge bad' }, 'DISABLED') : null),
      x.this_device ? null : [
        x.active ? h('button', { class: 'small danger', onclick: () => act(x, 'disable', 'Disable') }, 'Disable')
          : h('button', { class: 'small go', onclick: () => act(x, 'enable', 'Enable') }, 'Enable'),
        h('button', { class: 'small ghost', onclick: () => act(x, 'repair', 'Re-pair') }, 'Re-pair')]))));
}

function addDevice() {
  modal((close) => {
    const name = h('input', { placeholder: 'e.g. Forecourt tablet 1' });
    const kind = h('select', {}, h('option', { value: 'forecourt' }, 'Forecourt (attendant)'),
      h('option', { value: 'kiosk' }, 'Kiosk (cashier)'), h('option', { value: 'manager' }, 'Manager'));
    const out = h('div');
    const ok = h('button', { class: 'go', type: 'submit' }, 'Create pairing code');
    const submit = () => busy(ok, async () => {
      out.replaceChildren();
      const r = await api('api_mgr_device_create', { p_name: name.value, p_kind: kind.value });
      if (!r.ok) return out.append(msg(r.message));
      close(); showCode(name.value, r.data.pairing_code); devicesTab();
    });
    return h('form', { onsubmit: (e) => { e.preventDefault(); submit(); } },
      h('h2', {}, 'Add device'), h('label', {}, 'Device name'), name, h('label', {}, 'Type'), kind, out,
      h('div', { class: 'actions' }, h('button', { type: 'button', class: 'ghost', onclick: close }, 'Cancel'), ok));
  });
}

function showCode(name, code) {
  modal((close) => h('div', {},
    h('h2', {}, `Pairing code for “${name}”`),
    h('div', { class: 'code' }, code),
    h('p', {}, 'Open the app on the tablet, choose “Pair this tablet” and type this code. It works once and expires in 24 hours.'),
    h('div', { class: 'actions' }, h('button', { class: 'primary', onclick: close }, 'Done'))));
}

// ------------------------------------------------------------------ customers
let lastSearch = '';
async function customersTab() {
  const q = h('input', { type: 'search', placeholder: 'Search name, mobile or card number', value: lastSearch });
  const list = h('div');
  const search = async () => {
    lastSearch = q.value;
    list.replaceChildren(h('p', { class: 'muted' }, 'Searching…'));
    const r = await api('api_mgr_customers', { p_search: q.value }).catch((e) => ({ ok: false, message: e.message }));
    if (!r.ok) return list.replaceChildren(msg(r.message));
    list.replaceChildren(table([
      { label: 'Name', get: (c) => c.name },
      { label: 'Mobile', get: (c) => c.mobile },
      { label: 'Balance', num: true, get: (c) => money(c.balance_cents) },
      { label: 'Cap', num: true, get: (c) => (c.cap ? litres(c.cap) : 'default') },
      { label: 'Cards', get: (c) => c.cards.map((k) => `${k.uid}${k.status === 'blocked' ? ' (blocked)' : ''}`).join(', ') },
      { label: 'Status', get: (c) => (c.status === 'active' ? '' : h('span', { class: 'badge bad' }, c.status)) },
      { label: 'Last claim', get: (c) => fmtDate(c.last_claim) },
    ], r.data.customers, { onRow: (c) => customerDetail(c.id), empty: 'No customers found.' }),
    r.data.customers.length >= 200 ? h('p', { class: 'muted' }, 'Showing the first 200 matches. Narrow the search.') : '');
  };
  render(h('h1', {}, 'Customers'), customerDesk(), h('h2', {}, 'Find a customer'),
    h('form', { class: 'row', onsubmit: (e) => { e.preventDefault(); search(); } }, h('div', { class: 'grow' }, q), h('button', { class: 'primary' }, 'Search')),
    h('p'), list);
  search();
}

async function customerDetail(id) {
  const r = await api('api_mgr_customer_detail', { p_customer: id }).catch((e) => ({ ok: false, message: e.message }));
  if (!r.ok) return toast(r.message, 'bad');
  const { customer: c, cards, ledger, claims } = r.data;
  modal((close) => {
    const name = h('input', { value: c.name });
    const mobile = h('input', { inputmode: 'tel', value: c.mobile });
    const cap = h('input', { inputmode: 'decimal', value: c.cap ?? '', placeholder: `Default (${S.boot.settings.default_cap_litres} L)` });
    const status = h('select', {}, ['active', 'suspended'].map((s) => h('option', { value: s, selected: c.status === s }, s)));
    const notes = h('textarea', {}, c.notes || '');
    const out = h('div');
    const save = h('button', { class: 'go', type: 'submit' }, 'Save details');
    const amt = h('input', { inputmode: 'decimal', placeholder: 'e.g. 25,00 or -25,00' });
    const note = h('input', { placeholder: 'Reason (required)' });
    const out2 = h('div');
    const adj = h('button', { class: 'primary', type: 'submit' }, 'Apply adjustment');
    const reopen = () => { close(); customerDetail(id); };
    const submit = () => busy(save, async () => {
      out.replaceChildren();
      const capV = cap.value.trim() === '' ? null : Number(cap.value.replace(',', '.'));
      const u = await api('api_mgr_customer_update', { p_customer: id, p_name: name.value, p_mobile: mobile.value,
        p_cap: capV, p_status: status.value, p_notes: notes.value });
      if (!u.ok) return out.append(msg(u.message));
      toast('Customer saved.', 'ok'); reopen();
    });
    const adjust = () => busy(adj, async () => {
      out2.replaceChildren();
      const cents = parseRands(amt.value);
      if (cents == null || cents === 0) return out2.append(msg('Enter a non-zero amount in rand.'));
      if (!await confirmBox('Adjust balance', `${cents > 0 ? 'Add' : 'Deduct'} ${money(Math.abs(cents))} ${cents > 0 ? 'to' : 'from'} ${c.name}’s balance?`, 'Apply')) return;
      const a = await api('api_mgr_adjust', { p_customer: id, p_amount_cents: cents, p_note: note.value });
      if (!a.ok) return out2.append(msg(a.message));
      toast(`Adjusted. New balance ${money(a.data.balance_cents)}.`, 'ok'); reopen();
    });
    return h('div', {},
      h('div', { class: 'row' }, h('h2', { class: 'grow' }, c.name), h('button', { class: 'ghost', onclick: close }, 'Close')),
      h('div', { class: 'kpis' }, kpi('Balance', money(c.balance_cents)), kpi('Registered', fmtDate(c.created_at)),
        kpi('POPIA consent', fmtDateTime(c.consent_at))),
      h('div', { class: 'grid two' },
        h('form', { class: 'card', onsubmit: (e) => { e.preventDefault(); submit(); } },
          h('h3', {}, 'Details'),
          h('label', {}, 'Name'), name, h('label', {}, 'Mobile'), mobile,
          h('label', {}, 'Daily litre cap (blank = default)'), cap,
          h('label', {}, 'Status'), status, h('label', {}, 'Notes'), notes, out, h('p'), save),
        h('form', { class: 'card', onsubmit: (e) => { e.preventDefault(); adjust(); } },
          h('h3', {}, 'Adjust balance'),
          h('p', { class: 'muted' }, 'Use for corrections only. Positive adds, negative deducts. Recorded in the audit log.'),
          h('label', {}, 'Amount (R)'), amt, h('label', {}, 'Note'), note, out2, h('p'), adj)),
      h('h3', {}, 'Cards'),
      table([
        { label: 'Card', get: (k) => k.uid },
        { label: 'Status', get: (k) => k.status },
        { label: 'Issued', get: (k) => fmtDate(k.issued_at) },
        { label: 'Block reason', get: (k) => k.block_reason || '' },
      ], cards),
      h('h3', {}, 'Ledger'),
      table([
        { label: 'When', get: (l) => fmtDateTime(l.at) },
        { label: 'Type', get: (l) => l.type },
        { label: 'Amount', num: true, get: (l) => money(l.amount_cents) },
        { label: 'Detail', get: (l) => (l.type === 'earn' ? `${l.grade} ${litres(l.litres)} · receipt ${l.receipt}` : l.note || '') },
        { label: 'By', get: (l) => l.by || '' },
      ], ledger),
      h('h3', {}, 'Claims'),
      table([
        { label: 'When', get: (x) => fmtDateTime(x.at) },
        { label: 'Status', get: (x) => x.status },
        { label: 'Pump', num: true, get: (x) => x.pump },
        { label: 'Grade', get: (x) => x.grade },
        { label: 'Litres', num: true, get: (x) => litres(x.litres) },
        { label: 'Cashback', num: true, get: (x) => money(x.cashback_cents) },
        { label: 'Attendant', get: (x) => x.attendant || '' },
        { label: 'Reject reason', get: (x) => x.reject_reason || '' },
      ], claims));
  }, { wide: true });
}

// ------------------------------------------------------------------ reports
let range = null;
function reportsTab() {
  range = range || { from: todayLocal(-6), to: todayLocal() };
  const from = h('input', { type: 'date', value: range.from });
  const to = h('input', { type: 'date', value: range.to });
  const body = h('div');
  const run = async () => {
    range = { from: from.value, to: to.value };
    body.replaceChildren(h('p', { class: 'muted' }, 'Loading…'));
    const r = await api('api_mgr_report', { p_from: from.value, p_to: to.value }).catch((e) => ({ ok: false, message: e.message }));
    if (!r.ok) return body.replaceChildren(msg(r.message));
    body.replaceChildren(...reportBody(r.data));
  };
  const quick = (label, f, t) => h('button', { class: 'small ghost', type: 'button', onclick: () => { from.value = f; to.value = t; run(); } }, label);
  render(h('h1', {}, 'Reports'),
    h('form', { class: 'card', onsubmit: (e) => { e.preventDefault(); run(); } },
      h('div', { class: 'row' },
        h('div', { class: 'grow' }, h('label', {}, 'From'), from),
        h('div', { class: 'grow' }, h('label', {}, 'To'), to)),
      h('p'),
      h('div', { class: 'row' },
        quick('Today', todayLocal(), todayLocal()), quick('Yesterday', todayLocal(-1), todayLocal(-1)),
        quick('Last 7 days', todayLocal(-6), todayLocal()), quick('Last 30 days', todayLocal(-29), todayLocal()),
        h('span', { class: 'spacer' }), h('button', { class: 'primary' }, 'Run report'))),
    h('p'), body);
  run();
}

const claimCsvCols = [
  { label: 'Captured', get: (c) => fmtDateTime(c.captured_at) },
  { label: 'Status', get: (c) => c.status },
  { label: 'Pump', get: (c) => c.pump },
  { label: 'Grade', get: (c) => c.grade },
  { label: 'Litres', get: (c) => c.litres },
  { label: 'Rate c/L', get: (c) => c.rate },
  { label: 'Cashback R', get: (c) => (c.cashback_cents / 100).toFixed(2) },
  { label: 'Customer', get: (c) => c.customer },
  { label: 'Card', get: (c) => c.card },
  { label: 'Attendant', get: (c) => c.attendant },
  { label: 'PIN verified', get: (c) => (c.pin_verified ? 'yes' : 'NO (offline)') },
  { label: 'Decided by', get: (c) => c.decided_by },
  { label: 'Decided', get: (c) => fmtDateTime(c.decided_at) },
  { label: 'Namos receipt', get: (c) => c.receipt },
  { label: 'Reject reason', get: (c) => c.reject_reason },
];
const payoutCsvCols = [
  { label: 'Date', get: (p) => fmtDate(p.at) },
  { label: 'Time', get: (p) => fmtTime(p.at) },
  { label: 'Amount R', get: (p) => (p.amount_cents / 100).toFixed(2) },
  { label: 'Customer', get: (p) => p.customer },
  { label: 'Card', get: (p) => p.card },
  { label: 'Cashier', get: (p) => p.cashier },
  { label: 'Namos Paid Out ref', get: (p) => p.namos_ref },
];

function reportBody(d) {
  const sum = (rows, k) => rows.reduce((a, r) => a + Number(r[k] || 0), 0);
  const tag = `${range.from}_to_${range.to}`;
  return [
    h('div', { class: 'kpis' },
      kpi('Approved claims', sum(d.by_day, 'approved')),
      kpi('Approved litres', litres(sum(d.by_day, 'litres'))),
      kpi('Cashback earned', money(sum(d.by_day, 'earned_cents'))),
      kpi('Paid out', money(sum(d.by_day, 'payout_cents'))),
      kpi('Adjustments', money(sum(d.by_day, 'adjust_cents')))),
    h('div', { class: 'row' },
      h('button', { class: 'primary', onclick: () => downloadCsv(`claims_${tag}.csv`, claimCsvCols, d.claims) }, `Export claims CSV (${d.claims.length})`),
      h('button', { class: 'primary', onclick: () => downloadCsv(`payouts_${tag}.csv`, payoutCsvCols, d.payouts) }, `Export payouts CSV (${d.payouts.length})`)),
    h('h2', {}, 'By day'),
    table([
      { label: 'Day', get: (x) => fmtDate(x.day) },
      { label: 'Approved', num: true, get: (x) => x.approved },
      { label: 'Litres', num: true, get: (x) => litres(x.litres) },
      { label: 'Earned', num: true, get: (x) => money(x.earned_cents) },
      { label: 'Rejected', num: true, get: (x) => x.rejected },
      { label: 'Expired', num: true, get: (x) => x.expired },
      { label: 'Payouts', num: true, get: (x) => x.payouts },
      { label: 'Paid out', num: true, get: (x) => money(x.payout_cents) },
      { label: 'Adjustments', num: true, get: (x) => money(x.adjust_cents) },
    ], d.by_day),
    h('h2', {}, 'By grade (approved)'),
    table([
      { label: 'Grade', get: (x) => x.grade },
      { label: 'Claims', num: true, get: (x) => x.approved },
      { label: 'Litres', num: true, get: (x) => litres(x.litres) },
      { label: 'Earned', num: true, get: (x) => money(x.earned_cents) },
    ], d.by_grade),
    h('p', { class: 'muted' }, 'Compare approved litres per grade with the Namos pump/grade totals for the same days.'),
    h('h2', {}, 'By attendant'),
    table(attendantCols, d.by_attendant, { rowClass: (a) => (attendantFlag(a) ? 'flag' : '') }),
    h('h2', {}, 'By cashier'),
    table([
      { label: 'Cashier', get: (x) => x.name },
      { label: 'Approved', num: true, get: (x) => x.approved },
      { label: 'Rejected', num: true, get: (x) => x.rejected },
      { label: 'Payouts', num: true, get: (x) => x.payouts },
      { label: 'Paid out', num: true, get: (x) => money(x.payout_cents) },
    ], d.by_cashier),
  ];
}

// ------------------------------------------------------------------ audit
const ACTIONS = {
  pin_failed: 'Wrong PIN', setup_first_manager: 'First manager set up', device_paired: 'Device paired',
  customer_registered: 'Customer registered', card_replaced: 'Card replaced', card_blocked: 'Card blocked',
  payout: 'Payout', rate_changed: 'Rate changed', settings_changed: 'Settings changed', staff_saved: 'Staff saved',
  device_created: 'Device created', device_disable: 'Device disabled', device_enable: 'Device enabled',
  device_repair: 'Device re-paired', customer_updated: 'Customer updated', balance_adjusted: 'Balance adjusted',
};
async function auditTab() {
  const d = await load('Audit log', 'api_mgr_audit', { p_limit: 500 });
  if (!d) return;
  const filter = h('select', {}, h('option', { value: '' }, 'All actions'),
    Object.entries(ACTIONS).map(([k, v]) => h('option', { value: k }, v)));
  const body = h('div');
  const paint = () => body.replaceChildren(table([
    { label: 'When', get: (a) => fmtDateTime(a.at) },
    { label: 'Action', get: (a) => (a.action === 'pin_failed' ? h('span', { class: 'badge bad' }, ACTIONS[a.action]) : ACTIONS[a.action] || a.action) },
    { label: 'Staff', get: (a) => a.staff || '' },
    { label: 'Device', get: (a) => a.device || '' },
    { label: 'Detail', get: (a) => h('span', { class: 'mono', style: 'white-space:normal;font-size:.8rem' }, a.detail ? JSON.stringify(a.detail) : '') },
  ], d.entries.filter((a) => !filter.value || a.action === filter.value)));
  filter.onchange = paint;
  render(h('div', { class: 'row' }, h('h1', { class: 'grow' }, 'Audit log'), filter, h('button', { class: 'ghost', onclick: auditTab }, 'Refresh')),
    h('p', { class: 'muted' }, 'Latest 500 entries. Claims and approvals are in Reports; this log covers payouts, changes and wrong PINs.'),
    body);
  paint();
}
