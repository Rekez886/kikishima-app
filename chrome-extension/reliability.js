// Shared reliability helpers for the popup, service worker, and content script.
(() => {
  function uiLanguage(raw) {
    const value = String(raw || 'en').replace(/_/g, '-').toLowerCase();
    if (value === 'zh-hant' || value.startsWith('zh-tw') || value.startsWith('zh-hk') || value.startsWith('zh-mo')) return 'zh-Hant';
    if (value.startsWith('zh')) return 'zh-Hans';
    if (value.startsWith('ja')) return 'ja';
    if (value.startsWith('ko')) return 'ko';
    return 'en';
  }

  function hash(value) {
    let h = 0x811c9dc5;
    for (let i = 0; i < value.length; i++) {
      h ^= value.charCodeAt(i);
      h = Math.imul(h, 0x01000193);
    }
    return (h >>> 0).toString(36);
  }

  function trackIdentity(track, blocks) {
    const first = blocks && blocks.length ? blocks[0].text || '' : '';
    const last = blocks && blocks.length ? blocks[blocks.length - 1].text || '' : '';
    const raw = [
      track && (track.id || track.vssId) || '',
      track && (track.lang || track.languageCode) || '',
      track && track.kind || '',
      first,
      last,
    ].join('\u001f');
    return hash(raw);
  }

  function cacheKey(site, videoID, trackID, target) {
    return ['tr2', site || '', videoID || '', trackID || '', target || ''].join(':');
  }

  function missingRanges(from, to, completed) {
    const ranges = [];
    let start = null;
    for (let i = from; i < to; i++) {
      if (!completed.has(i)) {
        if (start === null) start = i;
      } else if (start !== null) {
        ranges.push([start, i]);
        start = null;
      }
    }
    if (start !== null) ranges.push([start, to]);
    return ranges;
  }

  function batchCompletion(translations, expected, terminal, readFailed) {
    const count = translations.reduce((n, value) => n + (value ? 1 : 0), 0);
    const terminalCount = terminal && typeof terminal.count === 'number' ? terminal.count : count;
    const serverComplete = !!terminal && (
      terminal.complete === true || (terminal.complete === undefined && terminalCount >= expected)
    );
    const complete = !readFailed && serverComplete && count >= expected;
    return {
      translations,
      count: terminalCount,
      complete,
      ...(complete ? {} : { error: terminal && terminal.error || 'stream_interrupted' }),
    };
  }

  const api = { batchCompletion, cacheKey, missingRanges, trackIdentity, uiLanguage };
  globalThis.KikiReliability = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})();
