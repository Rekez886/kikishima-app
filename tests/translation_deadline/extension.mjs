import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { setImmediate as tick, setTimeout as sleep } from 'node:timers/promises';
import { webcrypto as crypto } from 'node:crypto';
const require = createRequire(import.meta.url);
const reliability = require('../../chrome-extension/reliability.js');
const background = readFileSync('chrome-extension/background.js', 'utf8');
const content = readFileSync('chrome-extension/content.js', 'utf8');
const enc = new TextEncoder();
const sender = { tab: { id: 1 }, frameId: 0, documentId: 'document-a' };
function workerFixture() {
  let receive, changed; const calls = [], messages = [], pending = [];
  const chrome = { runtime: { onMessage: { addListener(fn) { receive = fn; } } },
    storage: { local: { get(_k, cb) { cb({ session: 'fixture' }); } }, onChanged: { addListener(fn) { changed = fn; } } },
    tabs: { query(_q, cb) { cb([]); }, sendMessage(...args) { messages.push(args); } } };
  const context = vm.createContext({ chrome, AbortController, AbortSignal, URL, TextDecoder, performance, setTimeout, clearTimeout,
    importScripts() {}, KikiReliability: reliability,
    fetch: async (_url, init) => {
      const stream = new ReadableStream({ start(c) { pending.push(c); }, cancel() {} });
      calls.push({ init, stream }); return new Response(stream);
    } });
  vm.runInContext(background, context);
  const send = (msg, origin = sender) => new Promise(resolve => receive(msg, origin, resolve));
  const job = extra => ({ type: 'translate', requestId: crypto.randomUUID(), videoId: 'v', trackKey: 't', target: 'Japanese', from: 0, lines: ['hello'], ...extra });
  return { calls, messages, pending, send, job, changed };
}
async function until(check) { for (let i = 0; i < 100; i++) { if (check()) return; await tick(); } assert.fail('expected async stage'); }

test('background uses shared remaining duration and cancels only the originating document', async () => {
  const f = workerFixture(), msg = f.job(); const task = f.send(msg);
  await until(() => f.calls.length === 1);
  assert.ok(Number(f.calls[0].init.headers['x-kikishima-timeout-ms']) <= 60000);
  await f.send({ type: 'cancelTranslations', requestIds: [msg.requestId] }, { ...sender, documentId: 'document-b' });
  assert.equal(f.calls[0].init.signal.aborted, false);
  await f.send({ type: 'cancelTranslations', requestIds: [msg.requestId] });
  const response = await task;
  assert.equal(response.complete, false); assert.equal(response.requestId, msg.requestId);
  assert.equal(f.calls[0].init.signal.aborted, true); assert.equal(f.calls[0].stream.locked, false);
});

test('background forwards bounded indices with identity and explicitly ends network after terminal', async () => {
  const f = workerFixture(), msg = f.job(); const task = f.send(msg); await until(() => f.calls.length);
  f.pending[0].enqueue(enc.encode('data: {"i":-1,"t":"bad"}\n\ndata: {"i":20,"t":"bad"}\n\ndata: {"i":0,"t":"good"}\n\ndata: {"done":true,"count":1,"complete":true}\n\n'));
  const result = await task;
  assert.equal(result.complete, true); assert.deepEqual(Array.from(result.translations), ['good']);
  assert.equal(f.messages.length, 1); assert.equal(f.messages[0][1].requestId, msg.requestId);
  assert.equal(f.messages[0][2].documentId, sender.documentId);
  assert.equal(f.calls[0].init.signal.aborted, true); assert.equal(f.calls[0].stream.locked, false);
});

test('total timeout and account/settings changes stop active background work', async () => {
  for (const mode of ['timeout', 'settings']) {
    const f = workerFixture(), msg = f.job(mode === 'timeout' ? { timeoutMs: 20 } : {});
    const task = f.send(msg); await until(() => f.calls.length);
    if (mode === 'settings') f.changed({ target: {} }, 'local');
    const result = await task;
    assert.equal(result.complete, false); assert.equal(f.calls[0].init.signal.aborted, true);
  }
});

// Execute the production lifecycle functions with UI/network/storage substituted.
// This exercises result ownership and retry logic without a browser or real account.
function functionSource(name) {
  const start = content.indexOf(`function ${name}(`), body = content.indexOf('{', start);
  assert.ok(start >= 0);
  let depth = 1, end = body + 1;
  // These functions have balanced literals; delimit by the next function/comment
  // below instead of attempting to parse arbitrary JS.
  for (; depth && end < content.length; end++) { if (content[end] === '{') depth++; if (content[end] === '}') depth--; }
  return (content.slice(start - 6, start) === 'async ' ? 'async ' : '') + content.slice(start, end);
}
function contentFixture() {
  const requests = [], cacheReads = [], cancellations = [];
  const context = vm.createContext({ crypto, performance, KikiReliability: reliability,
    setTimeout: (fn, delay) => setTimeout(fn, delay === 2000 ? 10 : delay), clearTimeout,
    chrome: { storage: { local: { get(keys, cb) { cacheReads.push({ keys, cb }); } } } },
    send: msg => msg.type === 'cancelTranslations' ? (cancellations.push(msg), Promise.resolve({})) : new Promise(resolve => requests.push({ msg, resolve })) });
  vm.runInContext(`let opt = {enabled:true,display:'both',target:'Japanese'}, state = null, cacheTimer = null;
    const activeRequests = new Map(); let lastIdx = -1; const BATCH = 24, FIRST_BATCH = 6;
    let playhead = 0; const site = {videoElement:() => ({currentTime:playhead})};
    const findIdx = value => value, onTime = () => ensureTranslated(playhead);
    const target = () => opt.target; const cacheKey = () => 'cache:' + target();
    const render = () => {}, note = () => {}, saveCache = () => {}, errorText = x => x, t = () => ({netError:'network'});
    ${['cancelPending','loadCache','ownsRequest','acceptLine','translateRange','ensureTranslated','onSeek'].map(functionSource).join('\n')}
    globalThis.api = {
      install(count = 1) { state = {key:'video',trackKey:'track',blocks:Array.from({length:count}, (_,i) => ({text:'source'+i})),tr:[],done:new Set(count === 1 ? [0] : []),firstDone:count === 1}; return state; },
      seek(at) { playhead = at; onSeek(); },
      changeTarget() { cancelPending(); opt.target = 'English'; state.tr = []; },
      begin() { return translateRange(0,1); },
      line(id,i,text) { const job=activeRequests.get(id); if(job) acceptLine(job,i,text); },
      cache:loadCache, ensure:() => ensureTranslated(0), cancel:cancelPending,
      get state() { return state; }
    };`, context);
  const complete = (i, translations = ['translated']) => requests[i].resolve({ ...requests[i].msg, translations, complete: translations.length === 1 });
  return { api: context.api, requests, cacheReads, cancellations, complete };
}

test('old target, old video owner and rewritten source cannot accept stream or final results', async () => {
  for (const change of ['target', 'owner', 'source']) {
    const f = contentFixture(), original = f.api.install(), work = f.api.begin();
    await until(() => f.requests.length);
    const id = f.requests[0].msg.requestId;
    if (change === 'target') f.api.changeTarget();
    if (change === 'owner') { f.api.cancel(); f.api.install(); }
    if (change === 'source') original.blocks[0].text = 'revised';
    f.api.line(id, 0, 'stale'); f.complete(0); await work;
    assert.equal(f.api.state.tr[0], undefined);
  }
});

test('current request accepts only valid source indices; old cache cannot write after target or owner changes', async () => {
  const f = contentFixture(); f.api.install(); const work = f.api.begin(); await until(() => f.requests.length);
  const id = f.requests[0].msg.requestId;
  f.api.line(id, -1, 'bad'); f.api.line(id, 10, 'bad'); f.api.line(id, 0, 'first');
  assert.equal(f.api.state.tr.length, 1); assert.equal(f.api.state.tr[0], 'first'); f.complete(0); await work;
  for (const change of ['target', 'owner']) {
    f.api.install(); const cached = f.api.cache();
    if (change === 'target') f.api.changeTarget(); else f.api.install();
    const read = f.cacheReads.at(-1); read.cb({ [read.keys[0]]: { n: 1, tr: ['stale-cache'] } }); await cached;
    assert.equal(f.api.state.tr[0], undefined);
  }
});

test('automatic missing-line recovery stops after one retry and keeps the original deadline', async () => {
  const f = contentFixture(); f.api.install(); const work = f.api.begin(); await until(() => f.requests.length);
  f.complete(0, []); await work; await sleep(20); assert.equal(f.requests.length, 2);
  assert.ok(f.requests[1].msg.timeoutMs < f.requests[0].msg.timeoutMs);
  f.complete(1, []); await sleep(25); f.api.ensure(); await sleep(25);
  assert.equal(f.requests.length, 2);
});


test('seeking cancels batches outside the new window and releases their reservations', async () => {
  const f = contentFixture(), state = f.api.install(200);
  f.api.ensure(); await until(() => f.requests.length === 2);
  const oldIds = f.requests.map(request => request.msg.requestId);
  f.api.seek(120); await until(() => f.requests.length === 4);
  assert.deepEqual(Array.from(f.cancellations[0].requestIds), oldIds);
  assert.equal(state.done.has(0), false);
  f.api.line(oldIds[0], 0, 'stale'); assert.equal(state.tr[0], undefined);
  f.complete(0); f.complete(1); f.api.cancel(); f.complete(2); f.complete(3);
});

test('source-only cancellation releases missing rows so translation can resume', async () => {
  const f = contentFixture(), state = f.api.install();
  const old = f.api.begin(); await until(() => f.requests.length);
  f.api.cancel(); assert.equal(state.done.has(0), false); f.complete(0); await old;
  f.api.ensure(); await until(() => f.requests.length === 2);
  f.complete(1); await tick(); assert.equal(state.tr[0], 'translated');
});


test('successive live cues and overlapping playback windows never resend reserved rows', async () => {
  const f = contentFixture(), state = f.api.install(); state.done.clear();
  f.api.ensure(); await until(() => f.requests.length === 1);
  state.blocks.push({text:'new cue'}); f.api.ensure(); await until(() => f.requests.length === 2);
  assert.equal(f.requests[0].msg.from, 0); assert.equal(f.requests[0].msg.lines.length, 1);
  assert.equal(f.requests[1].msg.from, 1); assert.equal(f.requests[1].msg.lines.length, 1);
  f.api.cancel(); f.complete(0); f.complete(1);
});
