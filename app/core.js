// Perth Road Rewards — shared core: API client, session, UI helpers, card reader.
import { CONFIG } from './config.js';

export const TZ = 'Africa/Johannesburg';

// ------------------------------------------------------------------ session
// Token lives in localStorage; the PIN lives in memory only and is lost on lock.
export const S = {
  token: null,     // device token
  boot: null,      // api_bootstrap data {device, settings, grades, staff}
  me: null,        // {id, name, role} once signed in
  pin: null,       // signed-in staff PIN (memory only)
  offlineSignIn: false,
  timers: [],      // intervals cleared on lock
  cleanups: [],    // functions run on lock
};

const hooks = { onDeviceLost: () => {}, onAuthLost: () => {} };
export function setHooks(h) { Object.assign(hooks, h); }

// ------------------------------------------------------------------ API
export class NetworkError extends Error {}

// Raw RPC call. Throws NetworkError when the server cannot be reached (or the
// gateway fails); otherwise returns the {ok, data | code, message} envelope.
export async function rpc(fn, params = {}) {
  let res;
  try {
    res = await fetch(`${CONFIG.url}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: CONFIG.key, 'Content-Type': 'application/json' },
      body: JSON.stringify(params),
      cache: 'no-store',
    });
  } catch {
    throw new NetworkError('No connection to the server.');
  }
  let body = null;
  try { body = await res.json(); } catch { /* empty or HTML body */ }
  if (res.status >= 500 || res.status === 408 || res.status === 429) {
    throw new NetworkError(`Server unavailable (${res.status}).`);
  }
  if (!res.ok) {
    return { ok: false, code: 'HTTP', message: (body && (body.message || body.hint)) || `Request failed (${res.status}).` };
  }
  return body || { ok: false, code: 'SERVER', message: 'Empty response from server.' };
}

// Authenticated call for the signed-in staff member.
export async function api(fn, params = {}) {
  const r = await rpc(fn, { p_token: S.token, p_staff: S.me && S.me.id, p_pin: S.pin, ...params });
  if (!r.ok) {
    if (r.code === 'DEVICE') hooks.onDeviceLost(r.message);
    else if (['PIN', 'LOCKED', 'STAFF'].includes(r.code) && S.me) hooks.onAuthLost(r.message);
  }
  return r;
}

export function errText(e) {
  return e instanceof NetworkError ? 'No connection. Check Wi-Fi and try again.' : (e && e.message) || String(e);
}

// ------------------------------------------------------------------ DOM helpers
export function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k === 'value') el.value = v;
    else if (k === 'checked') el.checked = !!v;
    else if (k === 'html') el.innerHTML = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  append(el, kids);
  return el;
}
function append(el, kids) {
  for (const k of kids.flat(Infinity)) {
    if (k == null || k === false) continue;
    el.appendChild(k instanceof Node ? k : document.createTextNode(String(k)));
  }
}

export const $ = (sel, root = document) => root.querySelector(sel);

export function render(...nodes) {
  const main = $('#main');
  main.replaceChildren();
  append(main, nodes);
  window.scrollTo(0, 0);
}

export function toast(text, kind = 'info', ms = 4500) {
  const el = h('div', { class: `msg ${kind}` }, text);
  $('#toasts').appendChild(el);
  setTimeout(() => el.remove(), ms);
}

export function msg(text, kind = 'bad') { return h('div', { class: `msg ${kind}` }, text); }

// Modal dialog. build(close) returns the content. Returns {close, el}.
export function modal(build, { wide = false } = {}) {
  const ov = $('#overlay');
  const box = h('div', { class: `modal${wide ? ' wide' : ''}`, role: 'dialog', 'aria-modal': 'true' });
  const close = () => { box.remove(); if (!ov.children.length) ov.hidden = true; };
  append(box, [build(close)]);
  ov.appendChild(box);
  ov.hidden = false;
  const first = box.querySelector('input:not([type=checkbox]), select, textarea');
  if (first) setTimeout(() => first.focus(), 50);
  return { close, el: box };
}
export function closeAllModals() { const ov = $('#overlay'); ov.replaceChildren(); ov.hidden = true; }

export function confirmBox(title, body, okLabel = 'Confirm', okClass = 'go') {
  return new Promise((resolve) => {
    modal((close) => h('div', {},
      h('h2', {}, title),
      typeof body === 'string' ? h('p', {}, body) : body,
      h('div', { class: 'actions' },
        h('button', { class: 'ghost', onclick: () => { close(); resolve(false); } }, 'Cancel'),
        h('button', { class: okClass, onclick: () => { close(); resolve(true); } }, okLabel))));
  });
}

// Run an async action with the button disabled; shows network errors as a toast.
export async function busy(btn, fn) {
  if (btn) { if (btn.disabled) return; btn.disabled = true; }
  try { return await fn(); }
  catch (e) { toast(errText(e), 'bad'); }
  finally { if (btn) btn.disabled = false; }
}

// ------------------------------------------------------------------ formatting
// R 1 234,56 (SA convention: space thousands separator, comma decimal).
export function money(cents) {
  const c = Math.round(Number(cents) || 0);
  const neg = c < 0;
  const abs = Math.abs(c);
  const rands = String(Math.floor(abs / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  return `${neg ? '−' : ''}R ${rands},${String(abs % 100).padStart(2, '0')}`;
}
// Rand input "12,50" / "12.50" / "R 1 234,50" → cents (null if invalid).
export function parseRands(s) {
  const t = String(s || '').replace(/[R\s]/gi, '').replace(',', '.');
  if (!/^-?\d+(\.\d{1,2})?$/.test(t)) return null;
  return Math.round(parseFloat(t) * 100);
}
export const centsToInput = (c) => (Number(c || 0) / 100).toFixed(2);
export function litres(n) { return `${Number(n || 0).toFixed(2).replace('.', ',')} L`; }
export function rate(c) { return `${Number(c || 0).toFixed(2).replace(/\.?0+$/, '').replace('.', ',')} c/L`; }

const dtf = (opts) => new Intl.DateTimeFormat('en-ZA', { timeZone: TZ, ...opts });
export const fmtTime = (ts) => ts ? dtf({ hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(ts)) : '';
export const fmtDate = (ts) => ts ? dtf({ day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(ts)) : '';
export const fmtDateTime = (ts) => ts ? `${fmtDate(ts)} ${fmtTime(ts)}` : '';
export function todayLocal(offsetDays = 0) {
  const d = new Date(Date.now() + offsetDays * 86400000);
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(d); // YYYY-MM-DD
}
export function ago(ts) {
  const m = Math.max(0, Math.round((Date.now() - new Date(ts).getTime()) / 60000));
  if (m < 1) return 'just now';
  if (m < 60) return `${m} min ago`;
  const hrs = Math.floor(m / 60);
  return `${hrs} h ${m % 60} min ago`;
}

export const normUid = (s) => String(s || '').replace(/[^0-9a-z]/gi, '').toUpperCase();
export const uuid = () => (crypto.randomUUID ? crypto.randomUUID()
  : '10000000-1000-4000-8000-100000000000'.replace(/[018]/g, (c) =>
    (c ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16)));

// ------------------------------------------------------------------ table helper
// cols: [{label, get(row) → string|Node, num?:bool}]
export function table(cols, rows, { onRow, rowClass, empty = 'Nothing to show.' } = {}) {
  if (!rows || !rows.length) return h('p', { class: 'muted' }, empty);
  return h('div', { class: 'table-wrap' }, h('table', {},
    h('thead', {}, h('tr', {}, cols.map((c) => h('th', { class: c.num ? 'num' : null }, c.label)))),
    h('tbody', {}, rows.map((r) => h('tr', {
      class: [onRow ? 'clickable' : '', rowClass ? rowClass(r) || '' : ''].join(' ').trim() || null,
      onclick: onRow ? () => onRow(r) : null,
    }, cols.map((c) => h('td', { class: c.num ? 'num' : null }, c.get(r))))))));
}

export function downloadCsv(filename, cols, rows) {
  const esc = (v) => {
    const s = v == null ? '' : String(v);
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const text = [cols.map((c) => esc(c.label)).join(','),
    ...rows.map((r) => cols.map((c) => esc(c.get(r))).join(','))].join('\r\n');
  const url = URL.createObjectURL(new Blob(['﻿' + text], { type: 'text/csv;charset=utf-8' }));
  const a = h('a', { href: url, download: filename });
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
}

// ------------------------------------------------------------------ keypad
// Numeric keypad bound to a display. decimals: digits after the point (0 = none).
export function keypad({ decimals = 0, maxLen = 6, mask = false, value = '', onChange = () => {}, onEnter }) {
  let v = value;
  const display = h('div', { class: 'display', 'aria-live': 'polite' });
  const show = (notify = true) => {
    display.textContent = v === '' ? ' ' : (mask ? '•'.repeat(v.length) : v.replace('.', ','));
    if (notify) onChange(v);
  };
  const press = (k) => {
    if (k === 'del') v = v.slice(0, -1);
    else if (k === 'clr') v = '';
    else if (k === '.') { if (decimals && !v.includes('.')) v = (v || '0') + '.'; }
    else {
      const [, dec] = v.split('.');
      if (dec !== undefined && dec.length >= decimals) return;
      if (v.replace('.', '').length >= maxLen) return;
      v = v === '0' ? k : v + k;
    }
    show();
  };
  const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', decimals ? '.' : 'clr', '0', 'del'];
  const pad = h('div', { class: 'keypad' }, keys.map((k) => h('button', {
    type: 'button', class: k === 'del' || k === 'clr' ? 'ghost' : null,
    'aria-label': k === 'del' ? 'Delete' : k === 'clr' ? 'Clear' : k,
    onclick: () => press(k),
  }, k === 'del' ? '⌫' : k === 'clr' ? 'C' : k === '.' ? ',' : k)));
  // Physical keyboard support while the keypad is on screen.
  const onKey = (e) => {
    if (!pad.isConnected) { document.removeEventListener('keydown', onKey); return; }
    if (e.target && ['INPUT', 'TEXTAREA', 'SELECT'].includes(e.target.tagName)) return;
    if (/^[0-9]$/.test(e.key)) press(e.key);
    else if (e.key === 'Backspace') press('del');
    else if ((e.key === '.' || e.key === ',') && decimals) press('.');
    else if (e.key === 'Enter' && onEnter) onEnter(v);
    else return;
    e.preventDefault();
  };
  document.addEventListener('keydown', onKey);
  show(false);
  return { display, pad, get value() { return v; }, set(nv) { v = nv; show(); } };
}

// ------------------------------------------------------------------ card reader
// Three inputs feed one handler: Web NFC (Android Chrome), a keyboard-wedge
// USB/Bluetooth reader (fast keystrokes + Enter) and manual entry.
let ndef = null;
let nfcOn = false;
let active = null;          // {el, onCard}
let lastUid = '', lastAt = 0;

export const nfcSupported = () => 'NDEFReader' in window;

function deliver(raw) {
  const uid = normUid(raw);
  if (uid.length < 4) { toast('Card not read correctly. Tap again.', 'warn'); return; }
  const now = Date.now();
  if (uid === lastUid && now - lastAt < 2500) return; // card held on the reader
  lastUid = uid; lastAt = now;
  if (active && active.el.isConnected) {
    if (navigator.vibrate) navigator.vibrate(80);
    active.onCard(uid);
  }
}

export async function startNfc(silent = false) {
  if (!nfcSupported() || nfcOn) return nfcOn;
  try {
    ndef = new window.NDEFReader();
    await ndef.scan();
    ndef.onreading = (e) => deliver(e.serialNumber);
    ndef.onreadingerror = () => toast('Card could not be read. Hold it still and tap again.', 'warn');
    nfcOn = true;
  } catch (e) {
    if (!silent) toast(`NFC not available: ${e.message || e}. Use the card number instead.`, 'warn', 7000);
  }
  document.querySelectorAll('.reader').forEach(paintReader);
  return nfcOn;
}

// Try to start NFC without a tap if permission was granted before.
export async function autoStartNfc() {
  if (!nfcSupported() || nfcOn || !navigator.permissions) return;
  try {
    const p = await navigator.permissions.query({ name: 'nfc' });
    if (p.state === 'granted') await startNfc(true);
  } catch { /* permission name unsupported */ }
}

let wedgeBuf = '', wedgeLast = 0;
document.addEventListener('keydown', (e) => {
  if (!active || !active.el.isConnected) return;
  const t = e.target;
  if (t && ['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName)) return;
  const now = performance.now();
  if (now - wedgeLast > 100) wedgeBuf = '';
  wedgeLast = now;
  if (e.key === 'Enter') {
    if (wedgeBuf.length >= 4) { e.preventDefault(); e.stopImmediatePropagation(); deliver(wedgeBuf); }
    wedgeBuf = '';
  } else if (e.key.length === 1 && /[0-9a-z:-]/i.test(e.key)) {
    wedgeBuf += e.key;
  }
}, true);

function paintReader(el) {
  el.classList.toggle('live', nfcOn);
  const st = el.querySelector('.nfc-state');
  const btn = el.querySelector('.nfc-start');
  if (st) st.textContent = nfcOn ? 'Reader ready — hold the card against the back of the tablet.'
    : nfcSupported() ? 'Tap “Start card reader” once, then tap cards.'
      : 'NFC not available on this device. Use a USB reader or type the card number.';
  if (btn) btn.hidden = nfcOn || !nfcSupported();
}

// Contactless symbol: a point and three arcs, drawn in currentColor.
const TAP_ICON = '<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="3">'
  + '<rect x="14" y="29" width="6" height="6" fill="currentColor" stroke="none"/>'
  + '<path d="M28 20a17 17 0 0 1 0 24M36 13a27 27 0 0 1 0 38M44 6a37 37 0 0 1 0 52"/></svg>';

export function cardReader({ title = 'Tap the customer’s card', onCard }) {
  const input = h('input', { type: 'text', inputmode: 'text', autocomplete: 'off', autocapitalize: 'characters',
    placeholder: 'Or type card number', 'aria-label': 'Card number' });
  const el = h('div', { class: 'reader' },
    h('div', { class: 'icon', 'aria-hidden': 'true', html: TAP_ICON }),
    h('div', { class: 'big' }, title),
    h('p', { class: 'nfc-state muted' }),
    h('button', { type: 'button', class: 'primary nfc-start', onclick: () => startNfc() }, 'Start card reader'),
    h('form', { onsubmit: (e) => { e.preventDefault(); const v = input.value; input.value = ''; deliver(v); } },
      input, h('button', { type: 'submit', class: 'ghost' }, 'Use')));
  active = { el, onCard };
  paintReader(el);
  autoStartNfc();
  return el;
}

// ------------------------------------------------------------------ device helpers
let wakeLock = null;
export async function keepAwake() {
  try {
    if ('wakeLock' in navigator && document.visibilityState === 'visible' && !wakeLock) {
      wakeLock = await navigator.wakeLock.request('screen');
      wakeLock.addEventListener('release', () => { wakeLock = null; });
    }
  } catch { /* not allowed (e.g. battery saver) */ }
}
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') keepAwake(); });

let audio = null;
export function unlockAudio() {
  if (!audio && (window.AudioContext || window.webkitAudioContext)) {
    audio = new (window.AudioContext || window.webkitAudioContext)();
  }
  if (audio && audio.state === 'suspended') audio.resume();
}
export function chime() {
  if (!audio) return;
  const t = audio.currentTime;
  [880, 1320].forEach((f, i) => {
    const o = audio.createOscillator(); const g = audio.createGain();
    o.frequency.value = f; o.type = 'sine';
    g.gain.setValueAtTime(0.0001, t + i * 0.18);
    g.gain.exponentialRampToValueAtTime(0.4, t + i * 0.18 + 0.02);
    g.gain.exponentialRampToValueAtTime(0.0001, t + i * 0.18 + 0.16);
    o.connect(g).connect(audio.destination);
    o.start(t + i * 0.18); o.stop(t + i * 0.18 + 0.18);
  });
}

// Inactivity auto-lock.
let idleTimer = null, idleSecs = 0, idleFn = null;
const bump = () => { if (idleFn) { clearTimeout(idleTimer); idleTimer = setTimeout(idleFn, idleSecs * 1000); } };
['pointerdown', 'keydown', 'touchstart'].forEach((ev) => document.addEventListener(ev, bump, { passive: true }));
export function startIdle(seconds, fn) { idleSecs = seconds; idleFn = fn; bump(); }
export function stopIdle() { clearTimeout(idleTimer); idleFn = null; }

export function every(ms, fn) { const id = setInterval(fn, ms); S.timers.push(id); return id; }
