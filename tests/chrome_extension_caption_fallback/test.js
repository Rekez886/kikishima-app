const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class FakeClassList {
  constructor() { this.values = new Set(); }
  add(...names) { names.forEach((name) => this.values.add(name)); }
  remove(...names) { names.forEach((name) => this.values.delete(name)); }
  contains(name) { return this.values.has(name); }
  toggle(name, force) {
    const on = force === undefined ? !this.values.has(name) : !!force;
    if (on) this.values.add(name); else this.values.delete(name);
    return on;
  }
}

class FakeElement {
  constructor(tag = 'div') {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parentElement = null;
    this.classList = new FakeClassList();
    this.style = { setProperty() {} };
    this._queries = new Map();
    this.textContent = '';
    this.innerHTML = '';
  }
  appendChild(child) { child.parentElement = this; this.children.push(child); return child; }
  insertBefore(child, before) {
    child.parentElement = this;
    const index = before ? this.children.indexOf(before) : -1;
    if (index < 0) this.children.push(child); else this.children.splice(index, 0, child);
    return child;
  }
  querySelector(selector) {
    if (!this._queries.has(selector)) this._queries.set(selector, this.appendChild(new FakeElement()));
    return this._queries.get(selector);
  }
  querySelectorAll() { return []; }
  addEventListener() {}
  removeEventListener() {}
  contains(node) { return node === this || this.children.some((child) => child.contains(node)); }
  remove() {
    if (!this.parentElement) return;
    this.parentElement.children = this.parentElement.children.filter((child) => child !== this);
    this.parentElement = null;
  }
  get firstChild() { return this.children[0] || null; }
  get firstElementChild() { return this.firstChild; }
}

async function main() {
  const documentElement = new FakeElement('html');
  const controls = new FakeElement();
  const player = new FakeElement();
  const below = new FakeElement();
  const video = { currentTime: 0, addEventListener() {}, removeEventListener() {} };
  let startup = null;
  let fallbackStarted = false;

  const document = {
    documentElement,
    body: new FakeElement('body'),
    createElement: (tag) => new FakeElement(tag),
    getElementById: () => null,
    contains: (node) => !!node.parentElement,
    addEventListener() {},
    removeEventListener() {},
  };
  const site = {
    name: 'youtube',
    navEvents: [],
    isVideoPage: () => true,
    videoKey: () => 'video-with-captions',
    videoElement: () => video,
    controlsMount: () => controls,
    overlayMount: () => player,
    mountPoint: () => below,
    getCues: async () => ({
      cues: [],
      tracks: [{ lang: 'en', name: 'English', kind: '' }],
      title: 'Captioned video',
      lang: 'en',
      audioLang: 'en',
      reason: 'fetch_failed',
    }),
    startLive() { fallbackStarted = true; return () => {}; },
  };
  const chrome = {
    runtime: {
      id: 'test-extension',
      getManifest: () => ({ version: '1.1.4' }),
      onMessage: { addListener() {} },
      sendMessage(message, callback) {
        if (message.type === 'hello') callback({ signedIn: true, ui: 'en', enabled: true });
        else callback({});
      },
    },
    storage: {
      local: {
        get(defaults, callback) { callback(defaults && !Array.isArray(defaults) ? { ...defaults, enabled: true } : {}); },
        set(_value, callback) { if (callback) callback(); },
        remove() {},
      },
    },
  };
  const window = {
    KikiSite: site,
    addEventListener() {},
    removeEventListener() {},
    open() {},
  };
  const context = vm.createContext({
    chrome,
    console,
    document,
    location: { href: 'https://www.youtube.com/watch?v=video-with-captions' },
    setInterval: () => 1,
    clearInterval() {},
    setTimeout(fn, delay) { if (delay === 600) startup = fn; return 1; },
    clearTimeout() {},
    URL,
    window,
  });
  const reliability = fs.readFileSync(path.join(__dirname, '../../chrome-extension/reliability.js'), 'utf8');
  vm.runInContext(reliability, context, { filename: 'reliability.js' });
  const source = fs.readFileSync(path.join(__dirname, '../../chrome-extension/content.js'), 'utf8');
  vm.runInContext(source, context, { filename: 'content.js' });
  assert.ok(startup, 'content script should schedule setup');
  await startup();
  assert.equal(fallbackStarted, true, 'captioned videos should fall back to rendered player captions when both APIs are empty');
}

main().then(() => console.log('caption fallback test passed'));
