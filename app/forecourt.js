// Perth Road Rewards — forecourt mode (attendant captures a pending claim).
import {
  S, rpc, api, NetworkError, h, render, toast, msg, busy, keypad, cardReader, modal,
  money, litres, rate, fmtDateTime, uuid,
} from './core.js';
import { frame, setTabs, paintStatus } from './app.js';

const LS_QUEUE = 'prr_queue';
let flushing = false;
let flusherStarted = false;

// ------------------------------------------------------------------ offline queue
// Items: {uid, pump, grade, litres, client_ref, captured_at, staff_id, staff_name, state, error}
// The PIN is never stored. Items are submitted later with p_offline = true, p_pin = null.
function loadQueue() { try { return JSON.parse(localStorage.getItem(LS_QUEUE) || '[]'); } catch { return []; } }
function saveQueue(q) { try { localStorage.setItem(LS_QUEUE, JSON.stringify(q)); } catch { /* storage full */ } paintStatus(); }

function queueClaim(c) {
  const q = loadQueue();
  q.push({ ...c, staff_id: S.me.id, staff_name: S.me.name, state: 'queued', error: null });
  saveQueue(q);
}

async function flushQueue() {
  if (flushing) return;
  const pending = loadQueue().filter((i) => i.state === 'queued');
  if (!pending.length) return;
  flushing = true;
  try {
    for (const item of pending) {
      let r;
      try {
        r = await rpc('api_claim_create', {
          p_token: S.token, p_staff: item.staff_id, p_pin: null, p_uid: item.uid, p_pump: item.pump,
          p_grade: item.grade, p_litres: item.litres, p_client_ref: item.client_ref,
          p_captured_at: item.captured_at, p_offline: true,
        });
      } catch (e) {
        if (e instanceof NetworkError) break; // still offline; try again later
        throw e;
      }
      if (r.code === 'DEVICE') break;
      const q = loadQueue();
      const idx = q.findIndex((x) => x.client_ref === item.client_ref);
      if (idx < 0) continue;
      if (r.ok) {
        q.splice(idx, 1);
        toast(`Offline claim sent: ${item.litres} L on pump ${item.pump}.`, 'ok');
      } else {
        q[idx].state = 'failed';
        q[idx].error = r.message;
        toast(`Offline claim refused: ${r.message}`, 'bad', 8000);
      }
      saveQueue(q);
    }
  } finally {
    flushing = false;
  }
}

function queueBadge() {
  const q = loadQueue();
  if (!q.length) return null;
  const failed = q.filter((i) => i.state === 'failed').length;
  return h('button', { class: `pill ${failed ? 'bad' : 'warn'}`, onclick: showQueue },
    `Queue ${q.length}${failed ? ` (${failed} failed)` : ''}`);
}

function showQueue() {
  modal((close) => {
    const body = h('div');
    const paint = () => {
      const q = loadQueue();
      body.replaceChildren(q.length ? h('div', { class: 'stack' }, q.map((i) => h('div', { class: 'card' },
        h('div', { class: 'row' },
          h('div', { class: 'grow' },
            h('b', {}, `Pump ${i.pump} · ${i.grade} · ${litres(i.litres)}`),
            h('div', { class: 'muted' }, `Card …${i.uid.slice(-4)} · ${i.staff_name} · ${fmtDateTime(i.captured_at)}`),
            i.state === 'failed' ? msg(i.error || 'Refused', 'bad') : h('span', { class: 'badge warn' }, 'Waiting to send')),
          i.state === 'failed' ? h('button', { class: 'small ghost', onclick: () => {
            saveQueue(loadQueue().filter((x) => x.client_ref !== i.client_ref)); paint();
          } }, 'Remove') : null))))
        : h('p', { class: 'muted' }, 'The queue is empty.'));
    };
    paint();
    const send = h('button', { class: 'primary', onclick: () => busy(send, async () => { await flushQueue(); paint(); }) }, 'Send now');
    return h('div', {},
      h('h2', {}, 'Offline claims'),
      h('p', { class: 'muted' }, 'Claims saved while the network was down. They are sent automatically every 30 seconds and when the connection returns. Failed claims were refused by the server; tell the manager.'),
      body,
      h('div', { class: 'actions' }, h('button', { class: 'ghost', onclick: close }, 'Close'), send));
  });
}

function startFlusher() {
  if (flusherStarted) return;
  flusherStarted = true;
  // Runs even while the tablet is locked: offline submissions do not need a PIN.
  setInterval(flushQueue, 30000);
  window.addEventListener('online', flushQueue);
  flushQueue();
}

// ------------------------------------------------------------------ screens
export function start() {
  frame.statusExtras = [queueBadge];
  paintStatus();
  startFlusher();
  setTabs([{ id: 'claim', label: 'New claim', render: cardStep }]);
}

function cardStep(note) {
  const out = h('div');
  const reader = cardReader({
    title: 'Tap the customer’s card',
    onCard: (uid) => lookup(uid, out),
  });
  render(
    h('h1', {}, 'New claim'),
    S.offlineSignIn ? msg('Signed in offline — claims are saved on this tablet and marked unverified.', 'warn') : null,
    note || null,
    reader, h('p'), out);
}

async function lookup(uid, out) {
  out.replaceChildren(h('p', { class: 'center muted' }, 'Checking card…'));
  if (S.offlineSignIn) return claimStep(uid, null);
  try {
    const r = await api('api_card_lookup', { p_uid: uid });
    if (!r.ok) return out.replaceChildren(msg(r.message));
    const c = r.data;
    if (c.card_status !== 'active') return out.replaceChildren(msg(`This card is blocked${c.block_reason ? `: ${c.block_reason}` : ''}. Send the customer to the kiosk.`));
    if (c.customer_status !== 'active') return out.replaceChildren(msg('This customer account is suspended. Send the customer to the kiosk.'));
    if (Number(c.litres_remaining) <= 0) return out.replaceChildren(msg(`${c.customer_name} has reached today’s limit of ${litres(c.cap_litres)}.`));
    claimStep(uid, c);
  } catch (e) {
    if (!(e instanceof NetworkError)) throw e;
    toast('No connection — card not checked. The claim will be saved and sent later.', 'warn', 6000);
    claimStep(uid, null);
  }
}

function claimStep(uid, info) {
  const st = S.boot.settings;
  const grades = S.boot.grades;
  let pump = null, grade = null;
  const maxFill = Number(st.max_litres_per_fill);
  const remaining = info ? Number(info.litres_remaining) : null;

  const est = h('div', { class: 'big' });
  const out = h('div');
  const submit = h('button', { class: 'go block xl', disabled: true }, 'Submit claim');

  const kp = keypad({ decimals: 2, maxLen: 5, onChange: () => update(), onEnter: () => submit.click() });

  // Pump set-up (manager → Pumps): pumps not in use are hidden; a pump with one
  // grade fills it in, a multi-grade pump offers only its own grades. Pumps
  // without set-up offer every grade.
  const cfg = new Map((S.boot.pumps || []).map((p) => [p.pump, p]));
  const gradesFor = (n) => {
    const c = cfg.get(n);
    const own = c && c.grades.length ? grades.filter((g) => c.grades.includes(g.code)) : [];
    return own.length ? own : grades;
  };
  // The customer's own rate per grade (company rate where set), from the card lookup;
  // offline the standard rate is shown and the server works out the exact cashback.
  const rateOf = (g) => Number(info && info.rates && info.rates[g.code] != null ? info.rates[g.code] : g.rate);
  const pumpNos = Array.from({ length: st.pump_count }, (_, i) => i + 1).filter((n) => !cfg.has(n) || cfg.get(n).active);

  const gradeHead = h('h2', { hidden: true }, '2. Fuel grade');
  const gradeBox = h('div');
  const litresHead = h('h2', {}, '2. Litres');
  const pumps = h('div', { class: 'grid pumps' }, pumpNos.map((n) => {
    const own = cfg.has(n) && cfg.get(n).grades.length ? gradesFor(n) : null;
    return h('button', { 'data-v': n, onclick: (e) => { pump = n; pick(pumps, e.currentTarget); showGrades(); update(); } },
      String(n), own ? h('small', {}, own.map((g) => g.code).join(' / ')) : null);
  }));

  function showGrades() {
    const list = gradesFor(pump);
    if (list.length === 1) {
      grade = list[0];
      gradeHead.hidden = true;
      gradeBox.replaceChildren(h('p', { class: 'big' }, `${grade.name} · ${rate(rateOf(grade))}`));
      litresHead.textContent = '2. Litres';
      return;
    }
    if (!grade || !list.includes(grade)) grade = null;
    gradeHead.hidden = false;
    litresHead.textContent = '3. Litres';
    const btns = h('div', { class: 'grid grades' }, list.map((g) =>
      h('button', { 'data-v': g.code, class: g === grade ? 'sel' : null, onclick: (e) => { grade = g; pick(btns, e.currentTarget); update(); } },
        g.name, h('small', {}, `${g.code} · ${rate(rateOf(g))}`))));
    gradeBox.replaceChildren(btns);
  }

  function pick(grid, btn) { grid.querySelectorAll('button').forEach((b) => b.classList.toggle('sel', b === btn)); }

  function update() {
    const l = Number(kp.value || 0);
    out.replaceChildren();
    let problem = null;
    if (l > maxFill) problem = `More than ${litres(maxFill)} in one fill is not allowed.`;
    else if (remaining != null && l > remaining) problem = `Only ${litres(remaining)} left today for this card.`;
    if (problem) out.append(msg(problem));
    est.textContent = grade && l > 0 ? `Estimated cashback: ${money(Math.round(l * rateOf(grade)))}` : '';
    submit.disabled = !(pump && grade && l > 0) || !!problem;
    submit.textContent = pump && grade && l > 0
      ? `Submit: pump ${pump} · ${grade.code} · ${litres(l)}` : 'Submit claim';
  }

  submit.onclick = () => busy(submit, async () => {
    const claim = {
      uid, pump, grade: grade.code, litres: Number(Number(kp.value).toFixed(2)),
      client_ref: uuid(), captured_at: new Date().toISOString(),
    };
    const summary = { ...claim, est: Math.round(claim.litres * rateOf(grade)), name: info && info.customer_name };
    if (S.offlineSignIn) { queueClaim(claim); return resultStep(summary, true); }
    try {
      const r = await api('api_claim_create', {
        p_uid: claim.uid, p_pump: claim.pump, p_grade: claim.grade, p_litres: claim.litres,
        p_client_ref: claim.client_ref, p_captured_at: claim.captured_at, p_offline: false,
      });
      if (!r.ok) { out.replaceChildren(msg(r.message)); return; }
      resultStep({ ...summary, est: r.data.cashback_cents, name: r.data.customer_name }, false);
    } catch (e) {
      if (!(e instanceof NetworkError)) throw e;
      queueClaim(claim);
      resultStep(summary, true);
    }
  });

  render(
    h('div', { class: 'row' },
      h('div', { class: 'grow' },
        h('div', { class: 'big' }, info ? info.customer_name : `Card …${uid.slice(-4)}`),
        info && info.company ? h('div', {}, info.company) : null,
        h('div', { class: 'muted' }, info
          ? `${litres(info.litres_remaining)} left today (limit ${litres(info.cap_litres)})`
          : 'Offline — card not checked')),
      h('button', { class: 'ghost', onclick: () => cardStep() }, 'Cancel')),
    h('h2', {}, '1. Pump'), pumps,
    gradeHead, gradeBox,
    litresHead, kp.display, kp.pad,
    h('p'), est, out, h('p'), submit);
}

function resultStep(c, queued) {
  const next = () => { clearTimeout(t); cardStep(); };
  const t = setTimeout(() => { if (S.me) cardStep(); }, 10000);
  render(h('div', { class: `banner ${queued ? 'warn' : 'ok'}` },
    h('div', { class: 'huge' }, queued ? 'SAVED OFFLINE' : 'PENDING'),
    h('p', { class: 'big' }, queued
      ? 'No connection. The claim is saved on this tablet and will be sent automatically.'
      : 'Customer must pay. The cashier will approve the claim.'),
    h('p', {}, [c.name, `Pump ${c.pump}`, c.grade, litres(c.litres), `est. ${money(c.est)}`].filter(Boolean).join(' · ')),
    h('button', { class: 'primary xl', onclick: next }, 'Next customer')));
}
