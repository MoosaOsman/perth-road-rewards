// Perth Road Rewards — kiosk mode (cashier): pending claims, payouts, customers, shift.
// The tab renderers are exported so the manager device can use them too.
import {
  S, api, h, render, toast, msg, busy, modal, confirmBox, cardReader, every, chime,
  money, litres, parseRands, centsToInput, fmtTime, fmtDateTime, ago, table, viewGuard,
} from './core.js';
import { frame, setTabs, setTabCount, paintStatus } from './app.js';

export function start() {
  frame.statusExtras = [];
  paintStatus();
  setTabs([
    { id: 'pending', label: 'Pending claims', render: pendingTab },
    { id: 'payout', label: 'Pay out', render: payoutTab },
    { id: 'customers', label: 'Customers', render: customersTab },
    { id: 'shift', label: 'Shift summary', render: shiftTab },
  ]);
  startPolling();
}

// ------------------------------------------------------------------ pending claims
let claims = [];
let seen = null;           // ids already announced
let listEl = null;

export function startPolling() {
  seen = null;
  const poll = async () => {
    try {
      const r = await api('api_claims_pending');
      if (!r.ok) return;
      claims = r.data.claims;
      const ids = new Set(claims.map((c) => c.id));
      if (seen && claims.some((c) => !seen.has(c.id) && !c.own_claim)) chime();
      seen = ids;
      setTabCount('pending', claims.length);
      paintClaims();
    } catch { /* offline: keep last list */ }
  };
  poll();
  every(10000, poll);
  every(30000, () => paintClaims()); // keep the "age" fresh
  S.cleanups.push(() => { claims = []; listEl = null; });
}

export function pendingTab() {
  listEl = h('div', { class: 'stack' });
  render(
    h('div', { class: 'row' }, h('h1', { class: 'grow' }, 'Pending claims'),
      h('span', { class: 'muted' }, 'Updates every 10 seconds')),
    h('p', { class: 'muted' }, 'Match each claim to the Namos till slip: pump, grade and litres must agree. Approve with the Namos receipt number.'),
    listEl);
  paintClaims();
}

function paintClaims() {
  if (!listEl || !listEl.isConnected) return;
  if (!claims.length) { listEl.replaceChildren(h('p', { class: 'muted center big' }, 'No claims waiting.')); return; }
  listEl.replaceChildren(...claims.map((c) => h('div', { class: 'card claim' },
    h('div', {},
      h('div', { class: 'facts' },
        h('span', {}, 'Pump ', h('b', {}, c.pump_no)),
        h('span', {}, h('b', {}, c.grade)),
        h('span', {}, h('b', {}, litres(c.litres))),
        h('span', {}, 'Cashback ', h('b', {}, money(c.cashback_cents)))),
      h('div', {}, `${c.customer_name} · card …${c.card_last4}`),
      h('div', { class: 'muted' }, `Attendant: ${c.attendant || '—'} · ${fmtTime(c.captured_at)} (${ago(c.captured_at)})`),
      !c.pin_verified ? h('span', { class: 'badge warn' }, 'OFFLINE · PIN NOT VERIFIED') : null,
      c.own_claim ? h('span', { class: 'badge grey' }, 'You captured this claim — another person must decide') : null),
    h('div', { class: 'acts' },
      h('button', { class: 'go', disabled: c.own_claim, onclick: () => approve(c) }, 'Approve'),
      h('button', { class: 'danger', disabled: c.own_claim, onclick: () => reject(c) }, 'Reject')))));
}

function claimLine(c) {
  return h('p', { class: 'big' }, `Pump ${c.pump_no} · ${c.grade} · ${litres(c.litres)} · ${money(c.cashback_cents)}`);
}

function approve(c) {
  modal((close) => {
    const rc = h('input', { class: 'huge-input mono', maxlength: 30, autocomplete: 'off', autocapitalize: 'characters', placeholder: 'Receipt no.' });
    const out = h('div');
    const ok = h('button', { class: 'go', type: 'submit' }, 'Approve');
    const submit = () => busy(ok, async () => {
      out.replaceChildren();
      const r = await api('api_claim_decide', { p_claim: c.id, p_approve: true, p_receipt: rc.value, p_reason: null });
      if (!r.ok) return out.append(msg(r.message));
      close();
      toast(`Approved. ${c.customer_name}’s balance is now ${money(r.data.balance_cents)}.`, 'ok');
      claims = claims.filter((x) => x.id !== c.id); setTabCount('pending', claims.length); paintClaims();
    });
    return h('form', { onsubmit: (e) => { e.preventDefault(); submit(); } },
      h('h2', {}, `Approve — ${c.customer_name}`), claimLine(c),
      h('label', {}, 'Namos receipt / transaction number from the till slip'), rc,
      h('p', { class: 'help' }, 'Only approve once the customer has paid and the slip matches. Each receipt number can be used once.'),
      out,
      h('div', { class: 'actions' }, h('button', { type: 'button', class: 'ghost', onclick: close }, 'Cancel'), ok));
  });
}

const REASONS = ['Customer didn’t pay / left', 'Wrong litres', 'Wrong card', 'Duplicate', 'Other'];
function reject(c) {
  modal((close) => {
    const other = h('input', { placeholder: 'Describe the reason', hidden: true });
    const out = h('div');
    let reason = null;
    const btns = h('div', { class: 'grid tiles' }, REASONS.map((t) => h('button', { type: 'button', onclick: (e) => {
      reason = t;
      btns.querySelectorAll('button').forEach((b) => b.classList.toggle('sel', b === e.currentTarget));
      other.hidden = t !== 'Other';
      if (t === 'Other') other.focus();
    } }, t)));
    const ok = h('button', { class: 'danger' }, 'Reject claim');
    ok.onclick = () => busy(ok, async () => {
      out.replaceChildren();
      const text = reason === 'Other' ? other.value.trim() && `Other: ${other.value.trim()}` : reason;
      if (!text) return out.append(msg('Choose a reason.'));
      const r = await api('api_claim_decide', { p_claim: c.id, p_approve: false, p_receipt: null, p_reason: text });
      if (!r.ok) return out.append(msg(r.message));
      close();
      toast('Claim rejected.', 'info');
      claims = claims.filter((x) => x.id !== c.id); setTabCount('pending', claims.length); paintClaims();
    });
    return h('div', {},
      h('h2', {}, `Reject — ${c.customer_name}`), claimLine(c),
      h('label', {}, 'Reason'), btns, h('p'), other, out,
      h('div', { class: 'actions' }, h('button', { class: 'ghost', onclick: close }, 'Cancel'), ok));
  });
}

// ------------------------------------------------------------------ pay out
export function payoutTab() {
  const out = h('div');
  render(h('h1', {}, 'Pay out cashback'),
    h('p', { class: 'muted' }, 'The card must be present. Cash comes from the till and is recorded as a Paid Out in Namos.'),
    cardReader({ title: 'Tap the customer’s card', onCard: (uid) => payoutForm(uid, out) }), h('p'), out);
}

async function payoutForm(uid, out) {
  out.replaceChildren(h('p', { class: 'muted center' }, 'Checking card…'));
  const r = await api('api_card_lookup', { p_uid: uid }).catch((e) => ({ ok: false, message: e.message }));
  if (!r.ok) return out.replaceChildren(msg(r.message));
  const c = r.data;
  if (c.card_status !== 'active') return out.replaceChildren(msg(`Card blocked${c.block_reason ? `: ${c.block_reason}` : ''}.`));
  if (c.customer_status !== 'active') return out.replaceChildren(msg('This customer account is suspended. Refer to the manager.'));
  const limited = c.max_payout_day_cents != null;       // null = no daily payout limit
  const leftToday = limited ? Math.max(0, c.max_payout_day_cents - c.paid_out_today_cents) : Infinity;
  const allowed = Math.min(c.balance_cents, leftToday);
  const facts = h('div', { class: 'kpis' },
    kpi('Customer', c.customer_name), kpi('Balance', money(c.balance_cents)),
    kpi('Paid out today', money(c.paid_out_today_cents)), kpi('Can pay now', money(allowed)));
  if (allowed < c.min_payout_cents) {
    return out.replaceChildren(facts, msg(c.balance_cents < c.min_payout_cents
      ? `Balance is below the ${money(c.min_payout_cents)} minimum payout.`
      : `Daily payout limit of ${money(c.max_payout_day_cents)} reached. Come back tomorrow.`, 'warn'));
  }
  const last3 = h('input', { class: 'huge-input mono', inputmode: 'numeric', maxlength: 3, autocomplete: 'off', placeholder: '•••' });
  const amount = h('input', { class: 'huge-input', inputmode: 'decimal', value: centsToInput(allowed) });
  const ref = h('input', { autocomplete: 'off', placeholder: 'Optional' });
  const err = h('div');
  const go = h('button', { class: 'go block xl', type: 'submit' }, 'Confirm payout');
  out.replaceChildren(facts, h('form', { class: 'card', onsubmit: (e) => { e.preventDefault(); submit(); } },
    h('label', {}, `Last 3 digits of the customer’s mobile (${c.mobile_masked})`), last3,
    h('p', { class: 'help' }, 'Ask the customer to say them. Do not read them out.'),
    h('label', {}, 'Amount (R)'), amount,
    h('p', { class: 'help' }, `Minimum ${money(c.min_payout_cents)} · maximum now ${money(allowed)}${limited ? '' : ' (the full balance)'}`),
    h('label', {}, 'Namos Paid Out reference'), ref,
    err, h('p'), go));
  last3.focus();
  const submit = () => busy(go, async () => {
    err.replaceChildren();
    const cents = parseRands(amount.value);
    if (!/^\d{3}$/.test(last3.value)) return err.append(msg('Enter the 3 digits.'));
    if (cents == null || cents <= 0) return err.append(msg('Enter a valid amount.'));
    if (cents < c.min_payout_cents) return err.append(msg(`Minimum payout is ${money(c.min_payout_cents)}.`));
    if (cents > allowed) return err.append(msg(`Maximum now is ${money(allowed)}.`));
    if (!await confirmBox('Confirm payout', `Pay ${money(cents)} cash to ${c.customer_name}?`, 'Yes, pay out')) return;
    const p = await api('api_payout', { p_uid: uid, p_amount_cents: cents, p_mobile_last3: last3.value, p_namos_ref: ref.value });
    if (!p.ok) return err.append(msg(p.message));
    render(h('div', { class: 'banner ok' },
      h('div', { class: 'huge' }, `PAY ${money(p.data.amount_cents)} CASH FROM TILL`),
      h('p', { class: 'big' }, 'Record a Paid Out in Namos for this amount.'),
      h('p', {}, `${p.data.customer_name} · new balance ${money(p.data.balance_cents)}`),
      h('button', { class: 'primary xl', onclick: payoutTab }, 'Done')));
  });
}

function kpi(label, value) { return h('div', { class: 'kpi' }, h('div', { class: 'l' }, label), h('div', { class: 'v' }, value)); }

// ------------------------------------------------------------------ customers desk
export function customersTab() {
  render(h('h1', {}, 'Customers'), customerDesk());
}

// Four counter actions; returned as a node so the manager screen can embed it.
export function customerDesk() {
  return h('div', { class: 'grid two' },
    h('button', { class: 'primary xl', onclick: registerFlow }, 'Register new customer'),
    h('button', { class: 'xl', onclick: balanceFlow }, 'Check balance'),
    h('button', { class: 'xl', onclick: replaceFlow }, 'Replace lost card'),
    h('button', { class: 'danger xl', onclick: blockFlow }, 'Block card'));
}

function cardInfoBox(c) {
  return h('div', { class: 'card' },
    h('div', { class: 'big' }, c.customer_name),
    c.company ? h('div', {}, `Company: ${c.company}`) : null,
    h('div', {}, `Mobile ${c.mobile_masked} · card ${c.card_uid}`),
    h('div', {}, 'Balance ', h('b', {}, money(c.balance_cents)), ` · paid out today ${money(c.paid_out_today_cents)}`),
    h('div', { class: 'muted' }, `${litres(c.litres_today)} claimed today, ${litres(c.litres_remaining)} left (limit ${litres(c.cap_litres)})`),
    c.card_status !== 'active' ? msg(`Card blocked${c.block_reason ? `: ${c.block_reason}` : ''}`, 'bad') : null,
    c.customer_status !== 'active' ? msg('Customer account suspended', 'warn') : null);
}

const CONSENT = 'I agree that Perth Road Rewards may store my name, mobile number and fuel purchases to run this cashback scheme. '
  + 'My details will not be shared or used for marketing. I can ask the manager to see or delete my details at any time.';

// A new card must not belong to anyone yet. Checked as soon as it is tapped, before
// any details are asked for (the server refuses a used card as well).
async function newCardCheck(uid, out) {
  out.replaceChildren(h('p', { class: 'muted' }, 'Checking card…'));
  const r = await api('api_card_lookup', { p_uid: uid }).catch((e) => ({ ok: false, code: 'NETWORK', message: e.message }));
  if (!r.ok && r.code === 'CARD_UNKNOWN') { out.replaceChildren(); return true; }
  if (r.ok) {
    out.replaceChildren(msg(`This card is already registered to ${r.data.customer_name} (${r.data.mobile_masked}). `
      + 'Use a new card from the stock. To give an existing customer a new card, use Replace lost card.'));
  } else {
    out.replaceChildren(msg(r.message));
  }
  return false;
}

function registerFlow() {
  modal((close) => {
    let uid = null;
    const step = h('div');
    const cardStep = () => {
      const out = h('div');
      step.replaceChildren(cardReader({ title: 'Tap the NEW card', onCard: async (u) => { if (await newCardCheck(u, out)) { uid = u; formStep(); } } }),
        h('p'), out,
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'ghost', onclick: close }, 'Cancel')));
    };
    const formStep = () => {
      const name = h('input', { autocomplete: 'off', placeholder: 'Name and surname' });
      const mobile = h('input', { inputmode: 'tel', autocomplete: 'off', placeholder: '082 123 4567' });
      const consent = h('input', { type: 'checkbox' });
      const out = h('div');
      const ok = h('button', { class: 'go', type: 'submit' }, 'Register');
      step.replaceChildren(h('form', { onsubmit: (e) => { e.preventDefault(); submit(); } },
        h('p', {}, 'Card ', h('b', { class: 'mono' }, uid), ' ', h('button', { type: 'button', class: 'small ghost', onclick: cardStep }, 'Change')),
        h('label', {}, 'Customer name'), name,
        h('label', {}, 'Mobile number'), mobile,
        h('label', { class: 'check' }, consent, h('span', {}, h('b', {}, 'POPIA consent. '), 'Read this to the customer: “', CONSENT, '”')),
        out, h('div', { class: 'actions' }, h('button', { type: 'button', class: 'ghost', onclick: close }, 'Cancel'), ok)));
      name.focus();
      const submit = () => busy(ok, async () => {
        out.replaceChildren();
        const r = await api('api_customer_register', { p_name: name.value, p_mobile: mobile.value, p_consent: consent.checked, p_uid: uid });
        if (!r.ok) return out.append(msg(r.message));
        step.replaceChildren(msg('Customer registered. Hand over the card.', 'ok'), h('p'), cardInfoBox(r.data),
          h('div', { class: 'actions' }, h('button', { class: 'primary', onclick: close }, 'Done')));
      });
    };
    cardStep();
    return h('div', {}, h('h2', {}, 'Register new customer'), step);
  });
}

function balanceFlow() {
  modal((close) => {
    const out = h('div');
    return h('div', {}, h('h2', {}, 'Check balance'),
      cardReader({ onCard: async (uid) => {
        const r = await api('api_card_lookup', { p_uid: uid }).catch((e) => ({ ok: false, message: e.message }));
        out.replaceChildren(r.ok ? cardInfoBox(r.data) : msg(r.message));
      } }),
      h('p'), out, h('div', { class: 'actions' }, h('button', { class: 'ghost', onclick: close }, 'Close')));
  });
}

function replaceFlow() {
  modal((close) => {
    const mobile = h('input', { inputmode: 'tel', autocomplete: 'off', placeholder: 'Customer’s registered mobile' });
    const reason = h('input', { value: 'Lost card' });
    const step = h('div');
    const out = h('div');
    const ready = () => step.replaceChildren(cardReader({ title: 'Tap the NEW card', onCard: async (uid) => { if (await newCardCheck(uid, out)) submit(uid); } }));
    const submit = async (uid) => {
      out.replaceChildren();
      if (!mobile.value.trim()) return out.append(msg('Enter the mobile number first.'));
      if (!await confirmBox('Replace card', `Block all old cards for ${mobile.value} and issue card ${uid}? The balance moves to the new card.`, 'Replace')) return;
      const r = await api('api_card_replace', { p_mobile: mobile.value, p_new_uid: uid, p_reason: reason.value });
      if (!r.ok) return out.append(msg(r.message));
      step.replaceChildren(msg('New card issued. Old cards are blocked.', 'ok'), h('p'), cardInfoBox(r.data));
    };
    ready();
    return h('div', {}, h('h2', {}, 'Replace lost card'),
      h('p', { class: 'muted' }, 'Confirm the customer’s identity before replacing a card.'),
      h('label', {}, 'Mobile number'), mobile, h('label', {}, 'Reason'), reason, h('p'), step, out,
      h('div', { class: 'actions' }, h('button', { class: 'ghost', onclick: close }, 'Close')));
  });
}

function blockFlow() {
  modal((close) => {
    const reason = h('input', { value: 'Reported lost/stolen' });
    const out = h('div');
    return h('div', {}, h('h2', {}, 'Block card'),
      h('label', {}, 'Reason'), reason, h('p'),
      cardReader({ title: 'Tap or type the card to block', onCard: async (uid) => {
        out.replaceChildren();
        if (!await confirmBox('Block card', `Block card ${uid}? It cannot be used again.`, 'Block', 'danger')) return;
        const r = await api('api_card_block', { p_uid: uid, p_reason: reason.value });
        out.replaceChildren(r.ok ? msg(`Card ${r.data.card_uid} blocked.`, 'ok') : msg(r.message));
      } }),
      h('p', { class: 'help' }, 'If the card is lost, type the card number, or use “Replace lost card” with the customer’s mobile.'),
      out, h('div', { class: 'actions' }, h('button', { class: 'ghost', onclick: close }, 'Close')));
  });
}

// ------------------------------------------------------------------ shift summary
export async function shiftTab() {
  const stale = viewGuard();
  render(h('h1', {}, 'Shift summary'), h('p', { class: 'muted' }, 'Loading…'));
  const r = await api('api_shift_summary').catch((e) => ({ ok: false, message: e.message }));
  if (stale()) return;
  if (!r.ok) return render(h('h1', {}, 'Shift summary'), msg(r.message));
  const d = r.data;
  render(
    h('div', { class: 'row no-print' }, h('h1', { class: 'grow' }, 'Shift summary'),
      h('button', { class: 'ghost', onclick: shiftTab }, 'Refresh'),
      h('button', { class: 'primary', onclick: () => window.print() }, 'Print cash-up list')),
    h('h2', { class: 'no-print' }, `Me — ${S.me.name}`),
    h('div', { class: 'kpis no-print' },
      kpi('Claims approved', `${d.me.approved} · ${money(d.me.approved_cents)}`),
      kpi('Claims rejected', d.me.rejected),
      kpi('Payouts', `${d.me.payouts} · ${money(d.me.payout_cents)}`)),
    h('h2', { class: 'no-print' }, 'Whole site today'),
    h('div', { class: 'kpis no-print' },
      kpi('Approved', `${d.site.approved} · ${litres(d.site.approved_litres)}`),
      kpi('Cashback earned', money(d.site.approved_cents)),
      kpi('Pending now', d.site.pending),
      kpi('Expired today', d.site.expired),
      kpi('Payouts', `${d.site.payouts} · ${money(d.site.payout_cents)}`)),
    h('div', { class: 'card' },
      h('h2', {}, `Cash-up: cashback payouts — ${S.me.name}, ${d.day}`),
      h('p', { class: 'muted' }, 'Each line must match a Paid Out in Namos.'),
      table([
        { label: 'Time', get: (p) => fmtTime(p.at) },
        { label: 'Customer', get: (p) => p.customer },
        { label: 'Namos ref', get: (p) => p.namos_ref || '' },
        { label: 'Amount', num: true, get: (p) => money(p.amount_cents) },
      ], d.my_payouts, { empty: 'No payouts by you today.' }),
      h('p', { class: 'big' }, `Total: ${money(d.me.payout_cents)} (${d.me.payouts} payouts)`),
      h('p', { class: 'muted' }, `Printed ${fmtDateTime(new Date())}. Cashier signature: ____________________`)));
}
