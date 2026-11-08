// Perth Road Rewards — boot, first-run setup, pairing, sign-in and the app frame.
import {
  S, rpc, api, setHooks, NetworkError, errText, h, $, render, toast, msg, busy, keypad,
  startIdle, stopIdle, keepAwake, unlockAudio, closeAllModals,
} from './core.js';

const LS_TOKEN = 'prr_token';
const LS_BOOT = 'prr_boot';          // last bootstrap, so the forecourt can start offline
const IDLE = { forecourt: 90, kiosk: 300, manager: 600 };
const KIND_LABEL = { forecourt: 'Forecourt', kiosk: 'Kiosk', manager: 'Manager' };

const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* storage blocked */ } },
  del(k) { try { localStorage.removeItem(k); } catch { /* storage blocked */ } },
};

if ('serviceWorker' in navigator && location.protocol === 'https:') {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}

setHooks({
  onDeviceLost: (m) => { lock(); showFirstRun(m); },
  onAuthLost: (m) => { lock(m); },
});

// The tab bar sticks directly under the header, whose height changes with the
// screen width and the status pills shown (two rows on phones).
if ('ResizeObserver' in window) {
  new ResizeObserver(([e]) => document.documentElement.style.setProperty('--head-h', `${Math.ceil(e.target.getBoundingClientRect().height)}px`))
    .observe($('#top'));
}

window.addEventListener('online', () => paintStatus());
window.addEventListener('offline', () => paintStatus());
document.addEventListener('pointerdown', unlockAudio, { once: true });

// ------------------------------------------------------------------ frame
export const frame = {
  statusExtras: [],          // extra header nodes supplied by the active mode
  tabs: [], current: null,
};

export function paintStatus() {
  const st = $('#status');
  st.replaceChildren(...[
    ...frame.statusExtras.map((f) => f()),
    h('span', { class: `pill ${navigator.onLine ? 'ok' : 'bad'}` }, navigator.onLine ? 'Online' : 'Offline'),
    S.me ? h('span', { class: 'who' }, S.me.name) : null,
    S.me ? h('button', { class: 'pill warn', onclick: () => lock() }, 'Lock') : null,
  ].filter(Boolean));
}

function paintHeader() {
  const b = S.boot;
  $('#scheme').textContent = (b && b.settings.scheme_name) || 'Perth Road Rewards';
  document.title = $('#scheme').textContent;
  $('#device').textContent = b ? `${b.device.name} · ${KIND_LABEL[b.device.kind]} tablet` : '';
  paintStatus();
}

// tabs: [{id, label, render()}]
export function setTabs(tabs, first) {
  frame.tabs = tabs;
  const nav = $('#tabs');
  nav.hidden = tabs.length < 2;
  nav.replaceChildren(...tabs.map((t) => h('button', {
    'data-tab': t.id, onclick: () => showTab(t.id),
  }, t.label, h('span', { class: 'count', hidden: true }))));
  showTab(first || tabs[0].id);
}
export function showTab(id) {
  const t = frame.tabs.find((x) => x.id === id);
  if (!t) return;
  frame.current = id;
  $('#tabs').querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.tab === id));
  t.render();
}
export function setTabCount(id, n) {
  const c = $(`#tabs button[data-tab="${id}"] .count`);
  if (c) { c.textContent = n; c.hidden = !n; }
}

// ------------------------------------------------------------------ lock / sign-out
export function lock(reason) {
  stopIdle();
  S.timers.forEach(clearInterval); S.timers = [];
  S.cleanups.forEach((f) => { try { f(); } catch { /* ignore */ } }); S.cleanups = [];
  S.me = null; S.pin = null; S.offlineSignIn = false;
  frame.statusExtras = []; frame.tabs = [];
  $('#tabs').hidden = true;
  closeAllModals();
  if (S.boot) showSignIn(reason); else paintStatus();
}

// ------------------------------------------------------------------ boot
async function boot() {
  S.token = store.get(LS_TOKEN);
  if (!S.token) return showFirstRun();
  render(h('p', { class: 'center muted' }, 'Connecting…'));
  try {
    const r = await rpc('api_bootstrap', { p_token: S.token });
    if (!r.ok) {
      if (r.code === 'DEVICE') return showFirstRun(r.message);
      return render(msg(r.message), retryButton());
    }
    S.boot = r.data;
    store.set(LS_BOOT, JSON.stringify(r.data));
  } catch (e) {
    const cached = store.get(LS_BOOT);
    if (!(e instanceof NetworkError) || !cached) {
      return render(msg(`${errText(e)} The tablet must be online the first time it starts.`), retryButton());
    }
    S.boot = JSON.parse(cached);
    toast('Offline — using the last saved staff list.', 'warn');
  }
  paintHeader();
  showSignIn();
}

function retryButton() {
  return h('p', { class: 'center' }, h('button', { class: 'primary', onclick: boot }, 'Try again'));
}

// Refresh settings, grades and staff (e.g. on the sign-in screen).
export async function refreshBoot() {
  try {
    const r = await rpc('api_bootstrap', { p_token: S.token });
    if (r.ok) { S.boot = r.data; store.set(LS_BOOT, JSON.stringify(r.data)); paintHeader(); }
    else if (r.code === 'DEVICE') { showFirstRun(r.message); return false; }
  } catch { /* offline: keep cached */ }
  return true;
}

// ------------------------------------------------------------------ first run: setup or pairing
async function showFirstRun(reason) {
  S.boot = null; S.me = null; S.pin = null;
  $('#tabs').hidden = true;
  paintHeader();
  render(h('p', { class: 'center muted' }, 'Checking setup…'));
  let st;
  try {
    st = await rpc('api_setup_status');
  } catch (e) {
    return render(msg(errText(e)), h('p', { class: 'center' }, h('button', { class: 'primary', onclick: () => showFirstRun(reason) }, 'Try again')));
  }
  if (st.ok && st.data.scheme_name) $('#scheme').textContent = st.data.scheme_name;
  if (st.ok && st.data.needs_setup) return showSetup();
  showPair(reason);
}

function showSetup() {
  const name = h('input', { autocomplete: 'name', placeholder: 'Your full name' });
  const pin = h('input', { type: 'password', inputmode: 'numeric', maxlength: 6, autocomplete: 'new-password', placeholder: '4–6 digits' });
  const pin2 = h('input', { type: 'password', inputmode: 'numeric', maxlength: 6, autocomplete: 'new-password' });
  const dev = h('input', { value: 'Manager phone', placeholder: 'e.g. Manager phone' });
  const out = h('div');
  const go = h('button', { class: 'primary block xl', type: 'submit' }, 'Set up as manager');
  render(h('div', { class: 'card narrow stack' },
    h('h1', {}, 'First-time set-up'),
    h('p', {}, 'No staff exist yet. Create the first manager account. This device becomes the manager device.'),
    h('form', { onsubmit: (e) => { e.preventDefault(); submit(); } },
      h('label', {}, 'Name'), name,
      h('label', {}, 'PIN'), pin,
      h('label', {}, 'PIN again'), pin2,
      h('label', {}, 'Name for this device'), dev,
      h('div', { class: 'help' }, 'Remember the PIN — there is no recovery without database access.'),
      h('p'), out, go)));
  const submit = () => busy(go, async () => {
    out.replaceChildren();
    if (pin.value !== pin2.value) return out.append(msg('The two PINs do not match.'));
    const r = await rpc('api_setup_first_manager', { p_name: name.value, p_pin: pin.value, p_device_name: dev.value });
    if (!r.ok) return out.append(msg(r.message));
    store.set(LS_TOKEN, r.data.token);
    toast('Manager account created.', 'ok');
    boot();
  });
}

function showPair(reason) {
  const code = h('input', { class: 'huge-input mono', maxlength: 8, autocapitalize: 'characters', autocomplete: 'off', placeholder: 'XXXXXXXX' });
  const out = h('div');
  const go = h('button', { class: 'primary block xl', type: 'submit' }, 'Pair this tablet');
  const hadToken = !!store.get(LS_TOKEN);
  render(h('div', { class: 'card narrow stack' },
    h('h1', {}, 'Pair this tablet'),
    reason ? msg(reason, 'warn') : null,
    h('p', {}, 'On the manager device open Devices → Add device, then type the 8-character pairing code here.'),
    h('form', { onsubmit: (e) => { e.preventDefault(); submit(); } }, code, h('p'), out, go),
    hadToken ? h('p', { class: 'center' }, h('button', { class: 'ghost', onclick: boot }, 'Try the old pairing again')) : null));
  const submit = () => busy(go, async () => {
    out.replaceChildren();
    const r = await rpc('api_pair_device', { p_code: code.value });
    if (!r.ok) return out.append(msg(r.message));
    store.set(LS_TOKEN, r.data.token);
    store.del(LS_BOOT);
    toast(`Paired as “${r.data.name}”.`, 'ok');
    boot();
  });
}

// ------------------------------------------------------------------ sign-in
async function showSignIn(reason) {
  paintStatus();
  const kind = S.boot.device.kind;
  const grid = h('div', { class: 'grid tiles' });
  const paint = () => {
    const staff = S.boot.staff || [];
    grid.replaceChildren(...(staff.length ? staff.map((s) => h('button', { onclick: () => showPin(s) },
      h('span', { class: 'tile-name' }, s.name), h('small', {}, s.role)))
      : [h('p', { class: 'muted' }, 'No staff can sign in on this tablet yet. The manager adds staff under Staff.')]));
  };
  render(
    h('h1', {}, 'Who is working?'),
    reason ? msg(reason, 'warn') : null,
    h('p', { class: 'muted' }, kind === 'forecourt' ? 'Attendants and managers' : kind === 'kiosk' ? 'Cashiers and managers' : 'Managers only'),
    grid);
  paint();
  if (await refreshBoot()) paint();
}

function showPin(staff) {
  const out = h('div');
  const go = h('button', { class: 'primary block xl' }, 'Sign in');
  const kp = keypad({ mask: true, maxLen: 6, onEnter: () => go.click() });
  go.onclick = () => busy(go, async () => {
    out.replaceChildren();
    const pin = kp.value;
    if (!/^\d{4,6}$/.test(pin)) return out.append(msg('PIN must be 4 to 6 digits.'));
    try {
      const r = await rpc('api_sign_in', { p_token: S.token, p_staff: staff.id, p_pin: pin });
      if (!r.ok) {
        kp.set('');
        if (r.code === 'DEVICE') return showFirstRun(r.message);
        return out.append(msg(r.message));
      }
      S.me = { id: staff.id, name: r.data.name, role: r.data.role };
      S.pin = pin;
    } catch (e) {
      // Offline sign-in is allowed on the forecourt only: claims are then queued
      // without the PIN and flagged "unverified" for the cashier and manager.
      if (!(e instanceof NetworkError) || S.boot.device.kind !== 'forecourt') throw e;
      S.me = { id: staff.id, name: staff.name, role: staff.role };
      S.pin = null;
      S.offlineSignIn = true;
      toast('Offline: PIN not checked. Claims will be marked unverified.', 'warn', 7000);
    }
    startMode();
  });
  render(h('div', { class: 'narrow' },
    h('button', { class: 'ghost small', onclick: () => showSignIn() }, '← Back'),
    h('h1', { class: 'center' }, staff.name),
    h('p', { class: 'center muted' }, 'Enter your PIN'),
    kp.display, kp.pad, h('p'), out, go));
}

async function startMode() {
  const kind = S.boot.device.kind;
  unlockAudio();
  keepAwake();
  startIdle(IDLE[kind], () => lock('Locked after inactivity.'));
  const mod = await import(kind === 'forecourt' ? './forecourt.js' : kind === 'kiosk' ? './kiosk.js' : './manager.js');
  paintStatus();
  mod.start();
}

boot();
