// Kikishima · service worker
// 扩展独立运行：自行获取会话令牌并直连 api.kikishima.com
// 内容脚本只发消息，令牌与网络都在这里，页面拿不到令牌
importScripts('reliability.js');

const API = 'https://api.kikishima.com';

const get = (keys) => new Promise((r) => chrome.storage.local.get(keys, (v) => r(v || {})));
const set = (obj) => new Promise((r) => chrome.storage.local.set(obj, () => r()));

async function auth() {
  const { session, plan, enabled = false, accountEmail } = await get(['session', 'plan', 'enabled', 'accountEmail']);
  return { session, plan, enabled, accountEmail };
}

// A request belongs to one tab/document. Cancellation messages name only the
// caller's own request IDs; an old document cannot abort a replacement document.
const translations = new Map();
function translationOwner(sender) { return `${sender.tab?.id}:${sender.documentId || sender.frameId || 0}`; }
function cancelTranslations(owner, ids) {
  for (const job of translations.values()) {
    if ((owner == null || job.owner === owner) && (!ids || ids.includes(job.id))) job.controller.abort();
  }
}

async function translateBatch(msg, sender, sendResponse) {
  const identity = { requestId: msg.requestId, videoId: msg.videoId, target: msg.target, trackKey: msg.trackKey };
  const reply = value => sendResponse({ ...value, ...identity });
  if (typeof msg.requestId !== 'string' || !/^[a-f0-9-]{36}$/i.test(msg.requestId) ||
      !Array.isArray(msg.lines) || !msg.lines.length || msg.lines.length > 60) {
    reply({ error: 'invalid_request' }); return;
  }
  const owner = translationOwner(sender), key = `${owner}:${msg.requestId}`;
  if (translations.has(key)) { reply({ error: 'duplicate_request' }); return; }
  const controller = new AbortController();
  const job = { owner, id: msg.requestId, tabId: sender.tab?.id, controller };
  translations.set(key, job);
  const duration = Number.isFinite(msg.timeoutMs) ? Math.max(0, Math.min(60000, msg.timeoutMs)) : 60000;
  const end = performance.now() + duration;
  let phaseTimer, reader;
  const totalTimer = setTimeout(() => controller.abort(), duration);
  const phase = ms => { clearTimeout(phaseTimer); phaseTimer = setTimeout(() => controller.abort(), ms); };
  const abortRead = () => { if (reader) void reader.cancel().catch(() => {}); };
  controller.signal.addEventListener('abort', abortRead, { once: true });
  const acc = [];
  try {
    const { session } = await auth();
    if (!session) { reply({ error: 'unauthorized' }); return; }
    controller.signal.throwIfAborted();
    phase(10000);
    const res = await fetch(API + '/translate/batch', {
      method: 'POST', signal: controller.signal,
      headers: { 'content-type': 'application/json', authorization: 'Bearer ' + session,
        'x-kikishima-timeout-ms': String(Math.max(0, Math.floor(end - performance.now()))) },
      body: JSON.stringify({ lines: msg.lines, target: msg.target, glossary: msg.glossary || undefined }),
    });
    controller.signal.throwIfAborted();
    phase(20000);
    if (!res.ok || !res.body) {
      const j = await res.json().catch(() => ({}));
      if (res.status === 401 && (await auth()).session === session) await set({ session: '', plan: '', usage: null });
      reply({ error: j.error || ('http_' + res.status) }); return;
    }
    reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = '', terminal = null, readFailed = false;
    try {
      outer: while (true) {
        const { done, value } = await reader.read();
        controller.signal.throwIfAborted();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        if (buf.length > 200000) throw new Error('oversized_stream');
        let nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
          if (!line.startsWith('data:')) continue;
          let o; try { o = JSON.parse(line.slice(5)); } catch { continue; }
          if (o.done) { terminal = o; break outer; }
          if (Number.isInteger(o.i) && o.i >= 0 && o.i < msg.lines.length && typeof o.t === 'string' && o.t.trim()) {
            if (acc[o.i]) continue;
            acc[o.i] = o.t; phase(15000);
            if (sender.tab?.id != null) {
              try { chrome.tabs.sendMessage(sender.tab.id, { type: 'batchLine', ...identity, i: o.i, t: o.t, from: msg.from },
                sender.documentId ? { documentId: sender.documentId } : { frameId: sender.frameId || 0 }, () => void chrome.runtime.lastError); } catch {}
            }
          }
        }
      }
    } catch { readFailed = true; }
    reply(KikiReliability.batchCompletion(acc, msg.lines.length, terminal, readFailed));
  } catch { reply({ error: controller.signal.aborted ? 'cancelled' : 'network', translations: acc, complete: false }); }
  finally {
    clearTimeout(totalTimer); clearTimeout(phaseTimer);
    controller.signal.removeEventListener('abort', abortRead);
    if (reader) { void reader.cancel().catch(() => {}); reader.releaseLock(); }
    controller.abort();
    if (translations.get(key) === job) translations.delete(key);
  }
}
chrome.tabs.onRemoved?.addListener(tabId => {
  for (const job of translations.values()) if (job.tabId === tabId) job.controller.abort();
});
chrome.tabs.onUpdated?.addListener((tabId, change) => {
  if (change.status === 'loading') for (const job of translations.values()) if (job.tabId === tabId) job.controller.abort();
});

// OAuth（Google / Apple）：必须在 service worker 里跑 —— 在弹窗里发起的话，授权窗一开弹窗就失焦销毁，回调回不来
async function oauth(provider, sendResponse) {
  try {
    await set({ authError: '' });
    const encode = bytes => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    const state = encode(crypto.getRandomValues(new Uint8Array(32)));
    const verifier = encode(crypto.getRandomValues(new Uint8Array(32)));
    const challenge = encode(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
    const url = `${API}/auth/${provider}/start?rt=ext&ext=${chrome.runtime.id}&state=${state}&code_challenge=${challenge}&code_challenge_method=S256`;
    const redirect = await new Promise((resolve, reject) => {
      chrome.identity.launchWebAuthFlow({ url, interactive: true }, (r) => {
        const err = chrome.runtime.lastError;
        if (err || !r) reject(new Error(err ? err.message : 'cancelled')); else resolve(r);
      });
    });
    const u = new URL(redirect);
    if (u.origin !== `https://${chrome.runtime.id}.chromiumapp.org` || u.pathname !== '/') throw new Error('redirect_mismatch');
    if (u.searchParams.get('state') !== state) throw new Error('state_mismatch');
    const code = u.searchParams.get('code');
    if (!code) throw new Error(u.searchParams.get('error') || 'failed');
    const res = await fetch(API + '/auth/handoff', {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code, code_verifier: verifier }),
    });
    const j = await res.json().catch(() => ({}));
    if (!res.ok || !j.session) throw new Error(j.error || ('http_' + res.status));
    await set({ session: j.session, plan: j.plan, accountEmail: j.email || '', codeSent: false, enabled: true });
    sendResponse({ ok: true });
  } catch (e) {
    const msg = String((e && e.message) || e);
    // 用户自己关掉授权窗不算错误，不留红字
    await set({ authError: /cancel|closed by the user/i.test(msg) ? '' : msg });
    sendResponse({ error: msg });
  }
}

let planRequestGeneration = 0;
let billingPending = null;
function billingURL(raw) {
  try {
    const u = new URL(raw);
    if (u.protocol === 'https:' && !u.username && !u.password && !u.port &&
        ['polar.sh', 'buy.polar.sh', 'sandbox.polar.sh', 'sandbox-buy.polar.sh'].includes(u.hostname)) return u.href;
  } catch {}
  return null;
}
async function accountRequest(action, sendResponse) {
  const { session } = await auth();
  if (!session) { sendResponse({ error: 'unauthorized' }); return; }
  const isBilling = action !== 'me';
  if (billingPending) { sendResponse({ error: 'billing_busy' }); return; }
  const operation = {};
  if (isBilling) billingPending = operation;
  const generation = ++planRequestGeneration;
  try {
    const res = await fetch(API + (isBilling ? '/billing/' + action : '/me'), {
      method: isBilling ? 'POST' : 'GET',
      headers: { authorization: 'Bearer ' + session, 'content-type': 'application/json' },
      ...(isBilling ? { body: '{}' } : {}), signal: AbortSignal.timeout(20000),
    });
    const data = await res.json().catch(() => ({}));
    if ((await auth()).session !== session || generation !== planRequestGeneration) {
      sendResponse({ error: 'stale_account' }); return;
    }
    if (res.status === 401) {
      await set({ session: '', plan: '', usage: null });
      sendResponse({ error: 'unauthorized' }); return;
    }
    if (!res.ok) { sendResponse({ error: data.error || 'billing_unavailable' }); return; }
    if (action === 'checkout' || action === 'portal') {
      const url = billingURL(data.url);
      if (!url) { sendResponse({ error: 'billing_invalid_response' }); return; }
      await chrome.tabs.create({ url });
      sendResponse({ ok: true });
    } else {
      if (!['free', 'pro', 'none'].includes(data.plan)) { sendResponse({ error: 'billing_invalid_response' }); return; }
      await set({ plan: data.plan, usage: { tokens: data.tokens, quota: data.quota }, accountEmail: data.email || '' });
      sendResponse(data);
    }
  } catch {
    sendResponse({ error: 'billing_unavailable' });
  } finally {
    if (isBilling && billingPending === operation) billingPending = null;
  }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  const tabId = sender && sender.tab ? sender.tab.id : null;
  if (!msg || !msg.type) return false;

  if (msg.type === 'hello') {
    (async () => {
      const a = await auth();
      const { target, display, uiLang } = await get(['target', 'display', 'uiLang']);
      sendResponse({
        signedIn: !!a.session, plan: a.plan || '', email: a.accountEmail || '',
        enabled: a.enabled, target: target || '', display: display || '',
        ui: uiLang || (navigator.language || 'en'),
        version: chrome.runtime.getManifest().version,
      });
    })();
    return true;
  }

  if (msg.type === 'oauth') { oauth(msg.provider === 'apple' ? 'apple' : 'google', sendResponse); return true; }

  if (msg.type === 'cancelTranslations') { cancelTranslations(translationOwner(sender), msg.requestIds || []); sendResponse({ ok: true }); return false; }
  if (msg.type === 'translate') { translateBatch(msg, sender, sendResponse); return true; }

  if (msg.type === 'billing') {
    if (sender?.url !== chrome.runtime.getURL('popup.html') || !['checkout', 'portal', 'refresh'].includes(msg.action)) {
      sendResponse({ error: 'forbidden' }); return false;
    }
    accountRequest(msg.action, sendResponse);
    return true;
  }
  if (msg.type === 'me') {
    accountRequest('me', sendResponse);
    return true;
  }

  return false;
});

// 弹窗里改了开关 / 登录状态：通知所有 YouTube 标签页刷新自己的状态
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local') return;
  if ('session' in changes) { planRequestGeneration++; billingPending = null; }
  if (!('enabled' in changes || 'session' in changes || 'target' in changes || 'display' in changes)) return;
  cancelTranslations(null);
  chrome.tabs.query({ url: 'https://www.youtube.com/*' }, (tabs) => {
    for (const tb of tabs || []) {
      try { chrome.tabs.sendMessage(tb.id, { type: 'settingsChanged' }, () => void chrome.runtime.lastError); } catch (e) {}
    }
  });
});
