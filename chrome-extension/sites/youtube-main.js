// 跑在页面主世界：内容脚本在隔离世界碰不到播放器对象，这里代读并回传
window.addEventListener('message', (ev) => {
  if (ev.source !== window || !ev.data || !ev.data.__kiki) return;
  const kind = ev.data.__kiki, token = ev.data.token;
  const player = document.getElementById('movie_player');
  if (kind === 'getPlayerResponse') {
    let out = null;
    try {
      const r = player && typeof player.getPlayerResponse === 'function' ? player.getPlayerResponse() : (window.ytInitialPlayerResponse || null);
      if (r) {
        out = {
          videoId: r.videoDetails && r.videoDetails.videoId,
          title: r.videoDetails && r.videoDetails.title,
          tracks: (r.captions && r.captions.playerCaptionsTracklistRenderer && r.captions.playerCaptionsTracklistRenderer.captionTracks) || [],
          audioLang: (r.captions && r.captions.playerCaptionsTracklistRenderer && r.captions.playerCaptionsTracklistRenderer.defaultAudioLanguage)
            || (r.microformat && r.microformat.playerMicroformatRenderer && r.microformat.playerMicroformatRenderer.language) || '',
        };
      }
    } catch (e) { out = null; }
    window.postMessage({ __kiki: 'getPlayerResponse:reply', token, data: out }, '*');
  } else if (kind === 'getInnertube') {
    let out = null;
    try {
      const cfg = window.ytcfg;
      const get = (k) => (cfg && cfg.get ? cfg.get(k) : (cfg && cfg.data_ ? cfg.data_[k] : null));
      const key = get('INNERTUBE_API_KEY'), ctx = get('INNERTUBE_CONTEXT');
      if (key && ctx) out = { key, ctx };
    } catch (e) { out = null; }
    window.postMessage({ __kiki: 'getInnertube:reply', token, data: out }, '*');
  } else if (kind === 'getTranscriptParams') {
    // YouTube 自己的「显示文字记录」用的接口：拿得到字幕，timedtext 直链常被拒时靠它
    let out = null;
    try {
      const cfg = window.ytcfg;
      const key = cfg && cfg.get ? cfg.get('INNERTUBE_API_KEY') : (cfg && cfg.data_ && cfg.data_.INNERTUBE_API_KEY);
      const ctx = cfg && cfg.get ? cfg.get('INNERTUBE_CONTEXT') : (cfg && cfg.data_ && cfg.data_.INNERTUBE_CONTEXT);
      let params = null;
      const panels = (window.ytInitialData && window.ytInitialData.engagementPanels) || [];
      for (const p of panels) {
        const r = p && p.engagementPanelSectionListRenderer;
        if (!r || !/transcript/i.test(r.panelIdentifier || '')) continue;
        const cont = r.content && r.content.continuationItemRenderer;
        const ep = cont && cont.continuationEndpoint;
        params = (ep && ep.getTranscriptEndpoint && ep.getTranscriptEndpoint.params) || (ep && ep.continuationCommand && ep.continuationCommand.token) || null;
        if (params) break;
      }
      if (key && ctx) out = { key, ctx, params };
    } catch (e) { out = null; }
    window.postMessage({ __kiki: 'getTranscriptParams:reply', token, data: out }, '*');
  } else if (kind === 'getDeviceParams') {
    // timedtext 直链只带 fmt 会被拒：YouTube 自己请求时带的是一整套设备参数，这里照抄一份
    let out = null;
    try {
      const cfg = window.ytcfg;
      const get = (k) => (cfg && cfg.get ? cfg.get(k) : (cfg && cfg.data_ ? cfg.data_[k] : null));
      const p = new URLSearchParams(get('DEVICE') || '');
      const player = document.getElementById('movie_player');
      let cver = '';
      try { cver = player.getWebPlayerContextConfig().innertubeContextClientVersion; } catch (e) { cver = get('INNERTUBE_CLIENT_VERSION') || ''; }
      out = {
        fmt: 'json3', xorb: '2', xobt: '3', xovt: '3', c: 'WEB', cplayer: 'UNIPLAYER', cver,
        cbrand: p.get('cbrand'), cbr: p.get('cbr'), cbrver: p.get('cbrver'),
        cos: p.get('cos'), cosver: p.get('cosver'), cplatform: p.get('cplatform'),
      };
    } catch (e) { out = null; }
    window.postMessage({ __kiki: 'getDeviceParams:reply', token, data: out }, '*');
  } else if (kind === 'enableCaptions') {
    // 兜底路径：打开播放器自带字幕（不改用户的语言选择），我们从渲染结果里读文本
    try {
      if (player && typeof player.setOption === 'function') {
        const tracks = player.getOption('captions', 'tracklist') || [];
        if (tracks.length) player.setOption('captions', 'track', tracks[0]);
      }
    } catch (e) { /* 忽略 */ }
    window.postMessage({ __kiki: 'enableCaptions:reply', token, data: true }, '*');
  }
});
