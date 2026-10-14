const assert = require('node:assert/strict');
const {
  batchCompletion,
  cacheKey,
  missingRanges,
  trackIdentity,
  uiLanguage,
} = require('../../chrome-extension/reliability.js');

assert.equal(uiLanguage('zh-CN'), 'zh-Hans');
assert.equal(uiLanguage('zh-TW'), 'zh-Hant');
assert.equal(uiLanguage('zh-HK'), 'zh-Hant');
assert.equal(uiLanguage('zh-Hant'), 'zh-Hant');
assert.equal(uiLanguage('ja-JP'), 'ja');
assert.equal(uiLanguage('ko-KR'), 'ko');
assert.equal(uiLanguage('fr-FR'), 'en');

const blocks = [{ text: 'First cue' }, { text: 'Last cue' }];
const manual = trackIdentity({ lang: 'en', kind: '', vssId: '.en' }, blocks);
const automatic = trackIdentity({ lang: 'en', kind: 'asr', vssId: 'a.en' }, blocks);
assert.notEqual(manual, automatic);
assert.notEqual(
  cacheKey('youtube', 'abc', manual, 'Japanese'),
  cacheKey('youtube', 'abc', automatic, 'Japanese'),
);

assert.deepEqual(missingRanges(10, 16, new Set([10, 11, 14])), [[12, 14], [15, 16]]);
assert.deepEqual(missingRanges(10, 13, new Set([10, 11, 12])), []);

const complete = batchCompletion(['a', 'b'], 2, { done: true, count: 2, complete: true }, false);
assert.deepEqual(complete, { translations: ['a', 'b'], count: 2, complete: true });

const partial = batchCompletion(['a'], 2, { done: true, count: 1, complete: false, error: 'upstream_stream_interrupted' }, false);
assert.deepEqual(partial, {
  translations: ['a'],
  count: 1,
  complete: false,
  error: 'upstream_stream_interrupted',
});

const readFailure = batchCompletion(['a', 'b'], 2, null, true);
assert.equal(readFailure.complete, false);
assert.equal(readFailure.error, 'stream_interrupted');

console.log('extension reliability tests passed');
