import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync('chrome-extension/background.js', 'utf8');
const popupURL = 'chrome-extension://fixture/popup.html';
function fixture() {
  const stored = { session: 'account-a', plan: 'free', accountEmail: 'a@example.test' };
  const calls = [], opened = [], listeners = [];
  let receive;
  const change = values => {
    Object.assign(stored, values);
    listeners.forEach(fn => fn(Object.fromEntries(Object.keys(values).map(k => [k, {}])), 'local'));
  };
  const chrome = {
    storage: { local: { get(_keys, cb) { cb({ ...stored }); }, set(values, cb) { change(values); cb(); } },
      onChanged: { addListener(fn) { listeners.push(fn); } } },
    runtime: { getURL: () => popupURL, onMessage: { addListener(fn) { receive = fn; } } },
    tabs: { create: async ({ url }) => { opened.push(url); }, query(_q, cb) { cb([]); } },
  };
  const context = vm.createContext({ chrome, URL, AbortController, AbortSignal, performance, setTimeout, clearTimeout, importScripts() {},
    fetch: (url, init) => new Promise(resolve => { calls.push({ url, init, resolve }); }) });
  vm.runInContext(source, context);
  const send = (action, sender = { url: popupURL }, extra = {}) =>
    new Promise(resolve => receive({ type: action === 'me' ? 'me' : 'billing', action, ...extra }, sender, resolve));
  const reply = (i, data, status = 200) => calls[i].resolve({ ok: status >= 200 && status < 300, status, json: async () => data });
  return { stored, calls, opened, change, send, reply };
}
async function sent(f, n = 1) {
  for (let i = 0; i < 100; i++) { if (f.calls.length >= n) return; await new Promise(r => setImmediate(r)); }
  assert.fail('request not started');
}

test('checkout/portal use current session, fixed endpoint and empty payload, not popup identity', async () => {
  for (const action of ['checkout', 'portal']) {
    const f = fixture();
    const task = f.send(action, undefined, { user_id: 'victim', url: 'https://evil.test', plan: 'pro' });
    await sent(f);
    assert.equal(f.calls[0].url, 'https://api.kikishima.com/billing/' + action);
    assert.equal(f.calls[0].init.headers.authorization, 'Bearer account-a');
    assert.equal(f.calls[0].init.method, 'POST'); assert.equal(f.calls[0].init.body, '{}');
    f.reply(0, { url: 'https://buy.polar.sh/fixture' }); assert.equal((await task).ok, true);
    assert.deepEqual(f.opened, ['https://buy.polar.sh/fixture']);
    assert.equal(f.stored.plan, 'free', 'opening checkout is not payment proof');
  }
});

test('billing rejects unauthenticated, content-script and unknown actions', async () => {
  const f = fixture();
  assert.equal((await f.send('checkout', { url: 'https://www.youtube.com/' })).error, 'forbidden');
  assert.equal((await f.send('delete')).error, 'forbidden');
  f.change({ session: '' });
  assert.equal((await f.send('checkout')).error, 'unauthorized');
  assert.equal(f.calls.length, 0);
});

test('duplicate clicks create only one checkout', async () => {
  const f = fixture(), one = f.send('checkout');
  await sent(f);
  assert.equal((await f.send('checkout')).error, 'billing_busy');
  assert.equal(f.calls.length, 1);
  f.reply(0, { url: 'https://buy.polar.sh/fixture' }); await one;
});

test('billing rejects malformed, non-HTTPS, credentialed and unrelated provider URLs', async () => {
  for (const url of [undefined, 'javascript:alert(1)', 'http://polar.sh', 'https://polar.sh.evil.test', 'https://user@polar.sh']) {
    const f = fixture(), task = f.send('checkout'); await sent(f);
    f.reply(0, { url }); assert.equal((await task).error, 'billing_invalid_response');
    assert.equal(f.opened.length, 0);
  }
});

test('switching accounts rejects a late checkout and allows the new account to start one', async () => {
  const f = fixture(), old = f.send('checkout'); await sent(f);
  f.change({ session: 'account-b', plan: 'free' });
  const next = f.send('checkout'); await sent(f, 2);
  f.reply(0, { url: 'https://buy.polar.sh/old' }); assert.equal((await old).error, 'stale_account');
  assert.equal(f.opened.length, 0);
  f.reply(1, { url: 'https://buy.polar.sh/new' }); assert.equal((await next).ok, true);
  assert.deepEqual(f.opened, ['https://buy.polar.sh/new']);
});

test('late success and 401 from a previous account cannot overwrite or sign out the new one', async () => {
  for (const status of [200, 401]) {
    const f = fixture(), task = f.send('refresh'); await sent(f);
    f.change({ session: 'account-b', plan: 'free' });
    f.reply(0, { plan: 'pro', email: 'a@example.test' }, status); await task;
    assert.equal(f.stored.session, 'account-b'); assert.equal(f.stored.plan, 'free');
  }
});

test('a late translation 401 also cannot sign out a new billing account', async () => {
  const f = fixture(), old = f.send('translate', { url: 'https://www.youtube.com/', tab: { id: 1 } },
    { type: 'translate', requestId: '00000000-0000-4000-8000-000000000001', lines: ['hello'], target: 'Japanese' });
  await sent(f);
  f.change({ session: 'account-b' });
  f.reply(0, { error: 'unauthorized' }, 401); await old;
  assert.equal(f.stored.session, 'account-b');
});

test('an earlier /me cannot roll back a later restore, and restore accepts authoritative downgrade', async () => {
  const f = fixture(), old = f.send('me'); await sent(f);
  const restore = f.send('refresh'); await sent(f, 2);
  f.reply(1, { plan: 'pro', tokens: 7, quota: null, email: 'a@example.test' }); await restore;
  f.reply(0, { plan: 'free', tokens: 0, quota: 240000 }); await old;
  assert.equal(f.stored.plan, 'pro'); assert.equal(f.stored.usage.tokens, 7);
  const revoke = f.send('refresh'); await sent(f, 3);
  f.reply(2, { plan: 'free', tokens: 3, quota: 240000 }); await revoke;
  assert.equal(f.stored.plan, 'free');
});

test('provider errors and malformed state never erase existing entitlements', async () => {
  const f = fixture(); f.change({ plan: 'pro' });
  for (const [data, status] of [[{ error: 'billing_not_linked' }, 409], [{}, 200], [{ error: 'billing_not_configured' }, 503]]) {
    const task = f.send('refresh'), i = f.calls.length;
    await sent(f, i + 1); f.reply(i, data, status);
    assert.ok((await task).error); assert.equal(f.stored.plan, 'pro');
  }
});

test('popup uses authenticated billing actions and worker snapshots, without email purchase links', () => {
  const popup = readFileSync('chrome-extension/popup.js', 'utf8');
  assert.ok(!popup.includes('buy.polar.sh') && !popup.includes('customer_email'));
  for (const action of ['checkout', 'portal', 'refresh']) assert.ok(popup.includes(`billing('${action}', session)`));
  assert.ok(popup.includes("sendMessage({ type: 'me' }"));
});
