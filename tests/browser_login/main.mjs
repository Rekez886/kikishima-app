import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';

// Exercise the actual extension login function with an isolated browser/HTTP
// fixture. No extension, account, preferences or network are used.
const source = readFileSync('chrome-extension/background.js', 'utf8');
const login = source.slice(source.indexOf('async function oauth('), source.indexOf('chrome.runtime.onMessage.addListener'));
const extension = 'gekennmfdgkinclbjmnaembfcjoepplk';
const base = `https://${extension}.chromiumapp.org/`;

for (const provider of ['apple', 'google']) {
  for (const mode of ['success', 'wrong-state', 'wrong-origin', 'cancel', 'rejected']) {
    const stored = [], requests = [], opened = [];
    const chrome = { runtime: { id: extension, lastError: null }, identity: {
      launchWebAuthFlow({ url }, done) {
        const u = new URL(url); opened.push(u);
        if (mode === 'cancel') { chrome.runtime.lastError = { message: 'cancelled' }; done(); return; }
        const state = mode === 'wrong-state' ? 'other-attempt' : u.searchParams.get('state');
        done(`${mode === 'wrong-origin' ? 'https://other.invalid/' : base}?${new URLSearchParams({ code: 'one-use', state })}`);
      },
    } };
    const context = vm.createContext({
      API: 'https://fixture.invalid', chrome, crypto: webcrypto, TextEncoder, URL, btoa,
      set: async data => { stored.push(data); },
      fetch: async (url, options) => {
        requests.push({ url, ...options });
        return { ok: mode !== 'rejected', status: mode === 'rejected' ? 401 : 200,
          json: async () => mode === 'rejected' ? { error: 'invalid_code' }
            : { session: 'synthetic-session', plan: 'free', email: 'fixture@example.test' } };
      },
    });
    vm.runInContext(login, context);
    let result;
    await context.oauth(provider, value => { result = value; });
    const url = opened[0];
    assert.equal(url.pathname, `/auth/${provider}/start`);
    assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
    assert.match(url.searchParams.get('state'), /^[A-Za-z0-9_-]{43}$/);
    if (mode === 'success' || mode === 'rejected') {
      assert.equal(requests.length, 1);
      const payload = JSON.parse(requests[0].body);
      assert.deepEqual(Object.keys(payload).sort(), ['code', 'code_verifier']);
      assert.match(payload.code_verifier, /^[A-Za-z0-9_-]{43}$/);
      const digest = Buffer.from(await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(payload.code_verifier))).toString('base64url');
      assert.equal(digest, url.searchParams.get('code_challenge'));
      assert.equal(url.href.includes(payload.code_verifier), false);
      assert.equal(JSON.stringify(stored).includes(payload.code_verifier), false, 'verifier remains in memory only');
    } else {
      assert.equal(requests.length, 0, 'invalid/canceled callback must not exchange');
    }
    if (mode === 'success') {
      assert.equal(result.ok, true);
      assert.equal(stored.at(-1).session, 'synthetic-session');
    } else {
      assert.ok(result.error);
      assert.equal(stored.some(row => row.session), false);
      if (mode === 'cancel') assert.equal(stored.at(-1).authError, '');
    }
  }
}
console.log('PASS extension browser login: both providers, S256, callback origin/state, cancel and rejected exchange');
