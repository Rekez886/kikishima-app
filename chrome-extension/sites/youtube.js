// 站点适配器：YouTube。加新站点 = 再写一个同接口的文件 + manifest 里加 matches
// 接口：window.KikiSite = { name, isVideoPage, videoKey, videoElement, mountPoint, overlayMount, controlsMount, getCues, liveCues, navEvents }
(() => {
  function ask(kind, payload) {
    return new Promise((resolve) => {
      const token = Math.random().toString(36).slice(2);
      const onMsg = (ev) => {
        if (ev.source !== window || !ev.data || ev.data.__kiki !== kind + ':reply' || ev.data.token !== token) return;
        window.removeEventListener('message', onMsg); resolve(ev.data.data);
      };
      window.addEventListener('message', onMsg);
      window.postMessage({ __kiki: kind, token, ...(payload || {}) }, '*');
      setTimeout(() => { window.removeEventListener('message', onMsg); resolve(null); }, 4000);
    });
  }

  // 有人工轨优先与自动轨同语言的人工轨（= 原声语言），否则自动轨
  const isAuto = (x) => x.kind === 'asr' || /^a\./.test(x.vssId || '');
  const base = (l) => (l || '').split(/[-_]/)[0].toLowerCase();
  /// 选哪条轨：用户指定 > 视频原声语言 > 自动生成轨对应的语言 > 第一条人工轨
  /// （以前直接取「第一条非自动轨」，YouTube 把阿拉伯语排在最前时就选错了）
  function pickTrack(tracks, preferLang, audioLang) {
    if (!tracks || !tracks.length) return null;
    const byLang = (l) => tracks.find((x) => !isAuto(x) && base(x.languageCode) === base(l)) || tracks.find((x) => base(x.languageCode) === base(l));
    if (preferLang) { const want = byLang(preferLang); if (want) return want; }
    if (audioLang) { const want = byLang(audioLang); if (want) return want; }
    const auto = tracks.find(isAuto);
    if (auto) return byLang(auto.languageCode) || auto;
    return tracks.find((x) => !isAuto(x)) || tracks[0];
  }

  function parseJson3(j) {
    const cues = [];
    for (const ev of j.events || []) {
      if (!ev.segs) continue;
      const text = ev.segs.map((s) => s.utf8 || '').join('').replace(/\s+/g, ' ').trim();
      if (!text) continue;
      const start = (ev.tStartMs || 0) / 1000;
      // 每个词的出现时间：拿来做逐词高亮（自动生成的轨都带）
      const words = [];
      for (const s of ev.segs) {
        const w = (s.utf8 || '');
        if (!w.trim()) continue;
        words.push({ t: start + (s.tOffsetMs || 0) / 1000, w: w.replace(/\n/g, ' ') });
      }
      cues.push({ start, end: start + Math.max(0.5, (ev.dDurationMs || 0) / 1000), text, words });
    }
    return cues;
  }
  function parseXml(txt) {
    const doc = new DOMParser().parseFromString(txt, 'text/xml');
    const cues = [];
    for (const n of doc.querySelectorAll('text, p')) {
      const start = parseFloat(n.getAttribute('start') || (parseInt(n.getAttribute('t') || '0', 10) / 1000)) || 0;
      const dur = parseFloat(n.getAttribute('dur') || (parseInt(n.getAttribute('d') || '0', 10) / 1000)) || 2;
      const text = (n.textContent || '').replace(/\s+/g, ' ').trim();
      if (text) cues.push({ start, end: start + dur, text });
    }
    return cues;
  }
  // 字幕轨 URL 现在常需要额外参数；三种格式都试一遍，谁给出内容用谁
  async function fetchTrack(baseUrl, device) {
    // 带全套设备参数的那条最可能成功：YouTube 自己请求 timedtext 时就是这么带的
    let withDevice = null;
    if (device) {
      try {
        const u = new URL(baseUrl);
        for (const [k, v] of Object.entries(device)) if (v) u.searchParams.set(k, v);
        withDevice = u.toString();
      } catch (e) { withDevice = null; }
    }
    const variants = [
      ...(withDevice ? [withDevice] : []),
      baseUrl.includes('fmt=') ? baseUrl : baseUrl + '&fmt=json3',
      baseUrl.replace(/&fmt=\w+/, '') + '&fmt=srv3',
      baseUrl.replace(/&fmt=\w+/, ''),
    ];
    for (const url of variants) {
      try {
        const r = await fetch(url, { credentials: 'same-origin' });
        if (!r.ok) continue;
        const txt = await r.text();
        if (!txt.trim()) continue;
        const cues = txt.trim().startsWith('{') ? parseJson3(JSON.parse(txt)) : parseXml(txt);
        if (cues.length) return cues;
      } catch (e) { /* 下一个 */ }
    }
    return [];
  }

  // YouTube 的文字记录接口（和页面上「显示文字记录」按钮同一个），timedtext 直链拿不到时用它
  function findTranscriptParams(node) {
    let found = null;
    const walk = (n) => {
      if (found || !n || typeof n !== 'object') return;
      if (Array.isArray(n)) { n.forEach(walk); return; }
      if (n.getTranscriptEndpoint && n.getTranscriptEndpoint.params) { found = n.getTranscriptEndpoint.params; return; }
      for (const k of Object.keys(n)) walk(n[k]);
    };
    walk(node);
    return found;
  }
  /// 页面数据里没有 transcript 参数（站内跳转很常见）时，直接问 /youtubei/v1/next 要
  async function transcriptParamsViaApi(key, ctx, videoId) {
    try {
      const r = await fetch('https://www.youtube.com/youtubei/v1/next?key=' + encodeURIComponent(key), {
        method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ context: ctx, videoId }),
      });
      if (!r.ok) return null;
      return findTranscriptParams(await r.json());
    } catch (e) { return null; }
  }

  /// 播放器对象里没有 captions 时，直接问 innertube 的 /player 要（最权威的一份）
  async function tracksViaApi(videoId) {
    let cfg = await ask('getInnertube');
    if (!cfg || !cfg.key || !cfg.ctx) { console.warn('[Kikishima] no innertube config for player'); return null; }
    try {
      const r = await fetch('https://www.youtube.com/youtubei/v1/player?key=' + encodeURIComponent(cfg.key), {
        method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ context: cfg.ctx, videoId, contentCheckOk: true, racyCheckOk: true }),
      });
      if (!r.ok) { console.warn('[Kikishima] player api', r.status); return null; }
      const j = await r.json();
      const cl = j.captions && j.captions.playerCaptionsTracklistRenderer;
      return {
        tracks: (cl && cl.captionTracks) || [],
        audioLang: (cl && cl.defaultAudioLanguage) || (j.microformat && j.microformat.playerMicroformatRenderer && j.microformat.playerMicroformatRenderer.language) || '',
        title: (j.videoDetails && j.videoDetails.title) || '',
      };
    } catch (e) { console.warn('[Kikishima] player api failed', e); return null; }
  }

  async function fetchTranscript(videoId) {
    let cfg = await ask('getTranscriptParams');
    if (!cfg || !cfg.key || !cfg.ctx) cfg = Object.assign({}, await ask('getInnertube'), cfg || {});
    if (!cfg || !cfg.key || !cfg.ctx) { console.warn('[Kikishima] no innertube config'); return []; }
    if (!cfg.params) cfg.params = await transcriptParamsViaApi(cfg.key, cfg.ctx, videoId);
    if (!cfg.params) { console.warn('[Kikishima] no transcript params for', videoId); return []; }
    try {
      const r = await fetch('https://www.youtube.com/youtubei/v1/get_transcript?key=' + encodeURIComponent(cfg.key), {
        method: 'POST', credentials: 'same-origin',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ context: cfg.ctx, params: cfg.params }),
      });
      if (!r.ok) { console.warn('[Kikishima] get_transcript', r.status); return []; }
      const j = await r.json();
      const cues = [];
      const walk = (node) => {
        if (!node || typeof node !== 'object') return;
        if (Array.isArray(node)) { node.forEach(walk); return; }
        const seg = node.transcriptSegmentRenderer;
        if (seg) {
          const text = (seg.snippet && (seg.snippet.simpleText || (seg.snippet.runs || []).map((x) => x.text).join(''))) || '';
          const start = Number(seg.startMs || 0) / 1000;
          const end = Number(seg.endMs || 0) / 1000 || start + 2;
          const clean = text.replace(/\s+/g, ' ').trim();
          if (clean) cues.push({ start, end, text: clean });
          return;
        }
        for (const k of Object.keys(node)) walk(node[k]);
      };
      walk(j);
      cues.sort((a, b) => a.start - b.start);
      return cues;
    } catch (e) { console.warn('[Kikishima] transcript failed', e); return []; }
  }

  window.KikiSite = {
    name: 'youtube',
    isVideoPage() { return location.pathname.startsWith('/watch') && !!new URL(location.href).searchParams.get('v'); },
    videoKey() { return new URL(location.href).searchParams.get('v'); },
    videoElement() { return document.querySelector('#movie_player video') || document.querySelector('video'); },
    mountPoint() { return document.querySelector('ytd-watch-flexy #below') || document.querySelector('#below') || document.querySelector('#player'); },
    overlayMount() { return document.querySelector('#movie_player') || document.querySelector('.html5-video-player'); },
    controlsMount() { return document.querySelector('#movie_player .ytp-right-controls') || document.querySelector('.ytp-right-controls'); },
    navEvents: ['yt-navigate-finish'],

    /// 返回 { cues, tracks, title, lang, reason }；cues 为空时 reason 说明原因，界面据此提示而不是静默消失
    async getCues(preferLang) {
      const key = this.videoKey();
      let pr = null;
      for (let i = 0; i < 12 && !pr; i++) {
        pr = await ask('getPlayerResponse');
        if (!pr || pr.videoId !== key) { pr = null; await new Promise((r) => setTimeout(r, 250)); }
      }
      if (!pr) pr = { videoId: key, title: '', tracks: [], audioLang: '' };
      // 播放器对象里常常没有 captions（站内跳转尤其明显）：那就问接口要一份
      if (!(pr.tracks || []).length) {
        const api = await tracksViaApi(key);
        if (api && api.tracks.length) {
          pr = { videoId: key, title: pr.title || api.title, tracks: api.tracks, audioLang: pr.audioLang || api.audioLang };
          console.log('[Kikishima] tracks via player api:', api.tracks.length);
        }
      }
      const tracks = (pr.tracks || []).map((x) => ({ lang: x.languageCode, name: (x.name && (x.name.simpleText || (x.name.runs && x.name.runs[0] && x.name.runs[0].text))) || x.languageCode, kind: x.kind || '', vssId: x.vssId || '', baseUrl: x.baseUrl }));
      if (!tracks.length) {
        const viaPanel = await fetchTranscript(key);   // 有些视频 playerResponse 里没轨，但文字记录接口有
        return { cues: viaPanel, tracks: [], title: pr.title || '', lang: pr.audioLang || '', audioLang: pr.audioLang || '', reason: viaPanel.length ? '' : 'no_track' };
      }
      console.log('[Kikishima] tracks:', tracks.map((x) => x.lang + (isAuto(x) ? '(auto)' : '')).join(', '));
      const track = pickTrack(tracks, preferLang, pr.audioLang);
      // 直链常被拒，文字记录接口更稳：两条一起发，谁给出内容用谁（省掉一次串行等待）
      const device = await ask('getDeviceParams');
      const [direct, panel] = await Promise.all([fetchTrack(track.baseUrl, device), fetchTranscript(key)]);
      console.log('[Kikishima] picked', track.lang, '| direct', direct.length, '| transcript', panel.length);
      let cues = direct.length ? direct : panel;
      if (!cues.length) console.warn('[Kikishima] both caption sources empty', { track: track.lang, tracks: tracks.length });
      return { cues, tracks, title: pr.title || '', lang: track.lang || '', audioLang: pr.audioLang || track.lang || '', reason: cues.length ? '' : 'fetch_failed' };
    },

    /// 兜底：让播放器自己开字幕，从渲染出来的字幕元素实时收词（拿不到字幕轨时用）
    startLive(onCue) {
      ask('enableCaptions');
      const player = document.querySelector('#movie_player');
      const container = player && (player.querySelector('.ytp-caption-window-container') || player);
      if (!container) return () => {};
      let last = '';
      const read = () => {
        const segs = container.querySelectorAll('.ytp-caption-segment');
        if (!segs.length) return;
        const text = Array.from(segs).map((s) => s.textContent).join(' ').replace(/\s+/g, ' ').trim();
        if (!text || text === last) return;
        last = text;
        const v = document.querySelector('video');
        onCue({ start: v ? v.currentTime : 0, end: (v ? v.currentTime : 0) + 3, text });
      };
      const mo = new MutationObserver(read);
      mo.observe(container, { childList: true, subtree: true, characterData: true });
      const timer = setInterval(read, 400);
      return () => { mo.disconnect(); clearInterval(timer); };
    },
  };
})();
