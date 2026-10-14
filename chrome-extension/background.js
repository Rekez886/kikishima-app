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

/// 批量翻译：服务器按行流式返回，收一行立刻转给发起的标签页，最后返回全量结果
async function translateBatch(msg, tabId, sendResponse) {
  const { session } = await auth();
  if (!session) { sendResponse({ error: 'unauthorized' }); return; }
  const from = typeof msg.from === 'number' ? msg.from : 0;
  let res;
  try {
    res = await fetch(API + '/translate/batch', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer ' + session },
      body: JSON.stringify({ lines: msg.lines, target: msg.target, glossary: msg.glossary || undefined }),
    });
  } catch (e) {
    sendResponse({ error: 'network' }); return;
  }
  if (!res.ok || !res.body) {
    const j = await res.json().catch(() => ({}));
    if (res.status === 401) await set({ session: '', plan: '' });
    sendResponse({ error: j.error || ('http_' + res.status) });
    return;
  }
  const acc = [];
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = '', terminal = null, readFailed = false;
  try {
    outer:
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
        if (!line.startsWith('data:')) continue;
        const payload = line.slice(5).trim();
        if (!payload) continue;
        let o; try { o = JSON.parse(payload); } catch (e) { continue; }
        if (o.done) { terminal = o; break outer; }
        if (typeof o.i === 'number') {
          acc[o.i] = o.t;
          if (tabId != null) {
            try { chrome.tabs.sendMessage(tabId, { type: 'batchLine', i: o.i, t: o.t, from }, () => void chrome.runtime.lastError); } catch (e) {}
          }
        }
      }
    }
  } catch (e) { readFailed = true; }
  sendResponse(KikiReliability.batchCompletion(acc, msg.lines.length, terminal, readFailed));
}

// OAuth（Google / Apple）：必须在 service worker 里跑 —— 在弹窗里发起的话，授权窗一开弹窗就失焦销毁，回调回不来
async function oauth(provider, sendResponse) {
  try {
    await set({ authError: '' });
    const state = Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
    const url = `${API}/auth/${provider}/start?rt=ext&ext=${chrome.runtime.id}&state=${encodeURIComponent(state)}`;
    const redirect = await new Promise((resolve, reject) => {
      chrome.identity.launchWebAuthFlow({ url, interactive: true }, (r) => {
        const err = chrome.runtime.lastError;
        if (err || !r) reject(new Error(err ? err.message : 'cancelled')); else resolve(r);
      });
    });
    const u = new URL(redirect);
    if (u.searchParams.get('state') !== state) throw new Error('state_mismatch');
    const code = u.searchParams.get('code');
    if (!code) throw new Error(u.searchParams.get('error') || 'failed');
    const res = await fetch(API + '/auth/handoff', {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code }),
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

  if (msg.type === 'translate') { translateBatch(msg, tabId, sendResponse); return true; }

  if (msg.type === 'me') {
    (async () => {
      const { session } = await auth();
      if (!session) { sendResponse({ error: 'unauthorized' }); return; }
      try {
        const r = await fetch(API + '/me', { headers: { authorization: 'Bearer ' + session } });
        const j = await r.json().catch(() => ({}));
        if (r.status === 401) { await set({ session: '', plan: '' }); sendResponse({ error: 'unauthorized' }); return; }
        await set({ plan: j.plan, usage: { tokens: j.tokens, quota: j.quota } });
        sendResponse(j);
      } catch (e) { sendResponse({ error: 'network' }); }
    })();
    return true;
  }

  return false;
});

// 弹窗里改了开关 / 登录状态：通知所有 YouTube 标签页刷新自己的状态
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local') return;
  if (!('enabled' in changes || 'session' in changes || 'target' in changes || 'display' in changes)) return;
  chrome.tabs.query({ url: 'https://www.youtube.com/*' }, (tabs) => {
    for (const tb of tabs || []) {
      try { chrome.tabs.sendMessage(tb.id, { type: 'settingsChanged' }, () => void chrome.runtime.lastError); } catch (e) {}
    }
  });
});
