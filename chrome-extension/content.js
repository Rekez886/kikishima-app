// Kikishima · 内容脚本（站点无关；站点差异在 sites/*.js 的 window.KikiSite）
// 字幕轨 → 合句 → 提前分批送本机 Kikishima app 翻译 → 叠在视频上或贴视频下方，随播放同步
// 播放器控制条里有 Kikishima 按钮：开关、显示内容、译文语言、位置、字号
(() => {
  const FIRST_BATCH = 6;    // 头几句先翻，画面立刻有字
  const BATCH = 24;         // 之后按块翻，并行两块，跑在播放头前面
  const LANGS = [
    { code: 'Simplified Chinese', label: '简体中文' }, { code: 'Traditional Chinese', label: '繁體中文' },
    { code: 'Japanese', label: '日本語' }, { code: 'English', label: 'English' }, { code: 'Korean', label: '한국어' },
    { code: 'Spanish', label: 'Español' }, { code: 'French', label: 'Français' }, { code: 'German', label: 'Deutsch' },
    { code: 'Portuguese', label: 'Português' }, { code: 'Hebrew', label: 'עברית' },
  ];
  const STR = {
    'zh-Hans': { title: 'Kikishima 字幕', display: '字幕显示', both: '双语字幕', translation: '仅译文', source: '仅原文',      target: '翻译字幕', source_track: '用哪条字幕轨', spoken: '原声语言', auto: '自动', position: '字幕位置', overlay: '视频上', below: '视频下方', size: '字号',      spokenHint: '实时听译要先知道说的是什么语言',      notRunning: 'Kikishima 未运行：打开 Kikishima app 后刷新页面', signIn: '点扩展图标登录后即可使用', netError: '网络不通，稍后自动重试',
      style: '字幕样式', back: '返回', srcSizeL: '原文字号', trSizeL: '译文字号', boldL: '加粗', colorL: '颜色', bgL: '背景透明度', blurL: '背景模糊', outlineL: '描边样式', karaokeL: '逐字高亮', trFirstL: '译文在上', none: '无', shadow: '阴影', stroke: '描边', reset: '重置位置',
      quota: '本周免费额度已用完，升级 Pro 或等待重置', pool: '今日免费额度已用完，明天再来或升级 Pro',
      noTrack: '这个视频没有字幕轨，暂时没法出字幕', fetchFailed: '拿不到字幕轨，刷新页面再试一次',
      loading: '正在读取字幕…', error: '翻译暂时不可用', live: '实时听译中（听系统声音）', liveStart: '正在启动实时听译…',
      busy: 'Kikishima 正在别处显示字幕；先在 app 里停止再回来', stopped: '实时听译已停止；重新打开开关可再来一次', startFailed: '实时听译启动失败：检查 Kikishima 的录音权限',
      update: '扩展有新版本 %v，点这里下载' },
    'zh-Hant': { title: 'Kikishima 字幕', display: '字幕顯示', both: '雙語字幕', translation: '僅譯文', source: '僅原文',      target: '翻譯字幕', source_track: '用哪條字幕軌', spoken: '原聲語言', auto: '自動', position: '字幕位置', overlay: '影片上', below: '影片下方', size: '字級',      spokenHint: '即時聽譯要先知道說的是什麼語言',      notRunning: 'Kikishima 未執行：打開 Kikishima app 後重新整理頁面', signIn: '點擴充功能圖示登入後即可使用', netError: '網路不通，稍後自動重試',
      style: '字幕樣式', back: '返回', srcSizeL: '原文字級', trSizeL: '譯文字級', boldL: '加粗', colorL: '顏色', bgL: '背景透明度', blurL: '背景模糊', outlineL: '描邊樣式', karaokeL: '逐字高亮', trFirstL: '譯文在上', none: '無', shadow: '陰影', stroke: '描邊', reset: '重設位置',
      quota: '本週免費額度已用完，升級 Pro 或等待重設', pool: '今日免費額度已用完，明天再來或升級 Pro',
      noTrack: '這個影片沒有字幕軌，暫時無法顯示字幕', fetchFailed: '拿不到字幕軌，重新整理頁面再試一次',
      loading: '正在讀取字幕…', error: '翻譯暫時不可用', live: '即時聽譯中（聽系統聲音）', liveStart: '正在啟動即時聽譯…',
      busy: 'Kikishima 正在別處顯示字幕；先在 app 裡停止再回來', stopped: '即時聽譯已停止；重新打開開關可再來一次', startFailed: '即時聽譯啟動失敗：檢查 Kikishima 的錄音權限',
      update: '擴充功能有新版本 %v，點這裡下載' },
    ja: { title: 'Kikishima 字幕', display: '字幕の表示', both: '二言語字幕', translation: '訳文のみ', source: '原文のみ',      target: '訳文の言語', source_track: '使う字幕トラック', spoken: '音声の言語', auto: '自動', position: '字幕の位置', overlay: '動画の上', below: '動画の下', size: '文字サイズ',      spokenHint: 'リアルタイム翻訳には話されている言語の指定が必要です',      notRunning: 'Kikishimaが起動していません。アプリを開いて再読み込みしてください', signIn: '拡張機能のアイコンからログインしてください', netError: 'ネットワークに接続できません。あとで自動的に再試行します',
      style: '字幕スタイル', back: '戻る', srcSizeL: '原文の文字サイズ', trSizeL: '訳文の文字サイズ', boldL: '太字', colorL: '色', bgL: '背景の不透明度', blurL: '背景のぼかし', outlineL: '縁取り', karaokeL: '逐語ハイライト', trFirstL: '訳文を上に', none: 'なし', shadow: '影', stroke: '縁取り', reset: '位置をリセット',
      quota: '今週の無料枠を使い切りました。Proにするかリセットをお待ちください', pool: '本日の無料枠を使い切りました。明日またはProで',
      noTrack: 'この動画には字幕トラックがないため、字幕を表示できません', fetchFailed: '字幕トラックを取得できません。ページを再読み込みして試してください',
      loading: '字幕を読み込み中…', error: '翻訳を一時的に利用できません', live: 'リアルタイム翻訳中（システム音声）', liveStart: 'リアルタイム翻訳を開始しています…',
      busy: 'Kikishimaは別の場所で字幕を表示中です。アプリで停止してからお試しください', stopped: 'リアルタイム翻訳を停止しました。スイッチを入れ直すと再開します', startFailed: 'リアルタイム翻訳を開始できません。Kikishimaの録音権限を確認してください',
      update: '拡張機能の新しいバージョン %v があります。クリックしてダウンロード' },
    en: { title: 'Kikishima captions', display: 'Caption display', both: 'Bilingual', translation: 'Translation only', source: 'Source only',      target: 'Translate to', source_track: 'Caption track', spoken: 'Spoken language', auto: 'Auto', position: 'Position', overlay: 'Over video', below: 'Below video', size: 'Font size',      spokenHint: 'Live translation needs to know which language is spoken',      notRunning: 'Kikishima is not running: open the app and reload this page', signIn: 'Click the extension icon to sign in', netError: 'Network unavailable; will retry',
      style: 'Caption style', back: 'Back', srcSizeL: 'Source size', trSizeL: 'Translation size', boldL: 'Bold', colorL: 'Color', bgL: 'Background opacity', blurL: 'Background blur', outlineL: 'Outline', karaokeL: 'Word highlight', trFirstL: 'Translation on top', none: 'None', shadow: 'Shadow', stroke: 'Outline', reset: 'Reset position',
      quota: 'This week’s free minutes are used up; upgrade to Pro or wait for the reset', pool: 'Today’s free pool is used up; try tomorrow or upgrade to Pro',
      noTrack: 'This video has no caption track, so there is nothing to show', fetchFailed: "Couldn't load the caption track. Reload the page and try again",
      loading: 'Loading captions…', error: 'Translation temporarily unavailable', live: 'Listening and translating live', liveStart: 'Starting live translation…',
      busy: 'Kikishima is captioning something else; stop it in the app and come back', stopped: 'Live translation stopped; flip the switch to start again', startFailed: 'Live translation could not start: check Kikishima’s recording permission',
      update: 'Extension %v is available — click to download' },
    ko: { title: 'Kikishima 자막', display: '자막 표시', both: '이중 언어', translation: '번역만', source: '원문만',      target: '번역 언어', source_track: '사용할 자막 트랙', spoken: '음성 언어', auto: '자동', position: '자막 위치', overlay: '동영상 위', below: '동영상 아래', size: '글자 크기',      spokenHint: '실시간 번역에는 말하는 언어 지정이 필요합니다',      notRunning: 'Kikishima가 실행 중이 아닙니다. 앱을 열고 새로 고치세요', signIn: '확장 프로그램 아이콘을 눌러 로그인하세요', netError: '네트워크에 연결할 수 없습니다. 나중에 다시 시도합니다',
      style: '자막 스타일', back: '뒤로', srcSizeL: '원문 크기', trSizeL: '번역 크기', boldL: '굵게', colorL: '색상', bgL: '배경 불투명도', blurL: '배경 흐림', outlineL: '테두리', karaokeL: '단어 하이라이트', trFirstL: '번역을 위에', none: '없음', shadow: '그림자', stroke: '테두리', reset: '위치 초기화',
      quota: '이번 주 무료 시간을 모두 사용했습니다', pool: '오늘 무료 사용량을 모두 사용했습니다',
      noTrack: '이 영상에는 자막 트랙이 없어 자막을 표시할 수 없습니다', fetchFailed: '자막 트랙을 가져오지 못했습니다. 페이지를 새로고침해 보세요',
      loading: '자막을 불러오는 중…', error: '번역을 일시적으로 사용할 수 없습니다', live: '실시간 번역 중(시스템 소리)', liveStart: '실시간 번역을 시작하는 중…',
      busy: 'Kikishima가 다른 곳에서 자막을 표시 중입니다. 앱에서 중지한 뒤 다시 시도하세요', stopped: '실시간 번역이 중지되었습니다. 스위치를 다시 켜면 재개합니다', startFailed: '실시간 번역을 시작할 수 없습니다. Kikishima의 녹음 권한을 확인하세요',
      update: '확장 프로그램 %v 버전이 있습니다. 클릭해 다운로드' },
  };

  const site = window.KikiSite;
  if (!site) return;
  // 安装后默认不开启：按钮和面板照常显示，用户点开关才开始工作
  const DEFAULTS = {
    enabled: false, display: 'both', target: '', position: 'overlay', size: 22, sourceLang: '', spokenLang: '',
    // 样式（对齐 Trancy 的可调项）
    trSize: 100, srcSize: 62, trBold: true, srcBold: false, trColor: '#ffffff', srcColor: '#c8c8c8',
    bgOpacity: 55, bgBlur: true, outline: 'shadow', karaoke: true, trFirst: true,
    dragX: null, dragY: null,   // 用户把字幕拖到哪（相对播放器的百分比）
  };
  // 实时听译可选的原声语言（对应 app 的转写 locale）
  const SPOKEN = [
    { code: 'en_US', label: 'English' }, { code: 'ja_JP', label: '日本語' }, { code: 'zh_CN', label: '简体中文' },
    { code: 'zh_TW', label: '繁體中文' }, { code: 'ko_KR', label: '한국어' }, { code: 'es_ES', label: 'Español' },
    { code: 'fr_FR', label: 'Français' }, { code: 'de_DE', label: 'Deutsch' }, { code: 'pt_BR', label: 'Português' },
    { code: 'it_IT', label: 'Italiano' },
  ];
  // YouTube 给的语言码（en / ja-JP…）映射到转写 locale
  function toLocale(lang) {
    if (!lang) return '';
    const b = lang.toLowerCase().split(/[-_]/)[0];
    const hit = SPOKEN.find((x) => x.code.toLowerCase().startsWith(b));
    if (b === 'zh') return /tw|hk|hant/i.test(lang) ? 'zh_TW' : 'zh_CN';
    return hit ? hit.code : '';
  }
  let opt = { ...DEFAULTS };
  let app = { signedIn: false, ui: 'en', target: 'Simplified Chinese' };
  let setupGeneration = 0;
  const activeRequests = new Map();
  function cancelPending(predicate = () => true) {
    const jobs = [...activeRequests.values()].filter(predicate);
    const ids = jobs.map(job => job.requestId);
    for (const job of jobs) {
      clearTimeout(job.retryTimer);
      if (state === job.owner) for (let i = 0; i < job.lines.length; i++) {
        if (!state.tr[job.from + i]) state.done.delete(job.from + i);
      }
    }
    for (const id of ids) activeRequests.delete(id);
    if (cacheTimer) { clearTimeout(cacheTimer); cacheTimer = null; }
    if (ids.length) send({ type: 'cancelTranslations', requestIds: ids });
  }
  let state = null;       // { key, blocks, tr, requested, tracks, lang, live, stopLive }
  let bar = null, elTr = null, elSrc = null, elNote = null, panel = null, btn = null;
  let wordSpans = [], wordTimes = [], wordBlockIdx = -1;
  let lastIdx = -1, currentVideo = null, timeBound = null;
  const t = () => STR[app.ui] || STR.en;
  const target = () => opt.target || app.target || 'Simplified Chinese';
  // 实时听译用的转写 locale：用户选的 → 视频自身语言 → 空（让 app 用它的会议语言）
  // 版本比较：1.10.0 > 1.9.0
  function cmpVer(a, b) {
    const pa = String(a).split('.').map(Number), pb = String(b).split('.').map(Number);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      const x = pa[i] || 0, y = pb[i] || 0;
      if (x !== y) return x < y ? -1 : 1;
    }
    return 0;
  }
  const spokenLocale = () => opt.spokenLang || (state ? toLocale(state.audioLang || state.lang) : '') || '';

  function loadOpt() {
    return new Promise((resolve) => {
      try { chrome.storage.local.get(DEFAULTS, (v) => resolve({ ...DEFAULTS, ...(v || {}) })); }
      catch (e) { resolve({ ...DEFAULTS }); }
    });
  }
  /// 按「站点 + 视频 + 字幕轨 + 译文语言」缓存译文，最多留 20 个视频/轨道组合
  function cacheKey() { return state ? KikiReliability.cacheKey(site.name, state.key, state.trackKey, target()) : ''; }
  function loadCache() {
    return new Promise((resolve) => {
      const owner = state, language = target();
      const k = cacheKey();
      if (!k) return resolve();
      try {
        chrome.storage.local.get([k], (v) => {
          const hit = v && v[k];
          if (state === owner && language === target() && hit && Array.isArray(hit.tr) && hit.n === state.blocks.length) {
            hit.tr.forEach((tx, i) => { if (tx) state.tr[i] = tx; });
          }
          resolve();
        });
      } catch (e) { resolve(); }
    });
  }
  let cacheTimer = null;
  function saveCache() {
    if (!state) return;
    if (cacheTimer) clearTimeout(cacheTimer);
    const owner = state, language = target();
    cacheTimer = setTimeout(() => {
      if (state !== owner || language !== target()) return;
      const k = cacheKey(); if (!k) return;
      try {
        chrome.storage.local.set({ [k]: { n: state.blocks.length, tr: state.tr, at: 1 } });
        chrome.storage.local.get(null, (all) => {
          const keys = Object.keys(all || {}).filter((x) => x.startsWith('tr2:'));
          if (keys.length > 20) chrome.storage.local.remove(keys.slice(0, keys.length - 20));
        });
      } catch (e) {}
    }, 1500);
  }

  function saveOpt() {
    return new Promise((resolve) => {
      try { chrome.storage.local.set(opt, () => resolve()); } catch (e) { resolve(); }
    });
  }

  function send(msg) {
    return new Promise((resolve) => {
      try { chrome.runtime.sendMessage(msg, (resp) => resolve(resp || { error: 'no_response' })); }
      catch (e) { resolve({ error: 'app_unavailable' }); }
    });
  }
  function errorText(code) {
    switch (code) {
      case 'unauthorized': case 'no_session': return t().signIn;
      case 'network': case 'no_response': return t().netError;
      case 'unauthorized': return t().signIn;
      case 'quota_exceeded': return t().quota;
      case 'free_pool_exhausted': return t().pool;
      default: return t().error;
    }
  }

  // ---- 字幕条 ----
  function injectStyle() {
    if (document.getElementById('kiki-style')) return;
    const s = document.createElement('style');
    s.id = 'kiki-style';
    s.textContent = `
      #kiki-bar{font-family:-apple-system,"PingFang SC","Hiragino Sans",sans-serif;color:#fff;z-index:60;pointer-events:none}
      #kiki-bar.kiki-overlay{position:absolute;left:4%;right:4%;bottom:12%;text-align:center}
      #kiki-bar.kiki-drag{left:auto;right:auto;bottom:auto}
      #kiki-bar .kiki-grip{display:none;pointer-events:auto;cursor:grab;margin:0 auto 6px;width:46px;height:16px;border-radius:8px;background:rgba(0,0,0,.55);
        color:#ddd;font:11px/16px -apple-system,sans-serif;text-align:center;letter-spacing:2px}
      #kiki-bar:hover .kiki-grip{display:block}
      #kiki-bar.kiki-dragging .kiki-grip{cursor:grabbing;display:block}
      #kiki-bar.kiki-below{position:static;margin:10px 0 6px;padding:14px 20px;border-radius:12px;background:rgba(17,17,17,.94);text-align:left;box-shadow:0 2px 10px rgba(0,0,0,.25)}
      #kiki-bar .kiki-tr{line-height:1.4;white-space:pre-wrap;color:var(--kiki-tr-color,#fff);font-weight:var(--kiki-tr-weight,700);text-shadow:var(--kiki-shadow,none)}
      #kiki-bar .kiki-src{line-height:1.4;white-space:pre-wrap;color:var(--kiki-src-color,#c8c8c8);font-weight:var(--kiki-src-weight,400);text-shadow:var(--kiki-shadow,none);margin-top:4px}
      #kiki-bar .kiki-box{background:rgba(0,0,0,var(--kiki-bg,.55))}
      #kiki-bar.kiki-overlay .kiki-box{display:inline-block;max-width:96%;padding:10px 18px;border-radius:14px;text-align:center}
      #kiki-bar .kiki-src .kiki-w{color:var(--kiki-src-color,#c8c8c8);transition:color .12s}
      #kiki-bar .kiki-src .kiki-w.on{color:var(--kiki-hi,#fff)}
      #kiki-bar .kiki-tr.kiki-wait{opacity:.6}
      #kiki-bar .kiki-note{font-size:13px;color:#f0b35a;margin-top:4px}
      #kiki-bar .kiki-tr:empty,#kiki-bar .kiki-src:empty,#kiki-bar .kiki-note:empty{display:none}
      #kiki-bar.kiki-off{display:none}
      .kiki-btn{width:40px;height:100%;background:transparent;border:0;cursor:pointer;opacity:.9;font:600 15px/1 -apple-system,sans-serif;color:#fff}
      .kiki-btn:hover{opacity:1}
      .kiki-btn.kiki-active{color:#ffd479}
      #kiki-panel{position:absolute;right:12px;bottom:60px;width:290px;background:rgba(28,28,28,.97);color:#fff;border-radius:12px;padding:6px;z-index:70;
        font:14px/1.4 -apple-system,"PingFang SC","Hiragino Sans",sans-serif;box-shadow:0 8px 30px rgba(0,0,0,.5)}
      #kiki-panel .row{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:9px 12px;border-radius:8px}
      #kiki-panel .row:hover{background:rgba(255,255,255,.08)}
      #kiki-panel select,#kiki-panel input[type=range]{background:transparent;color:#fff;border:0;font:13px -apple-system,sans-serif;max-width:150px}
      #kiki-panel select option{background:#222;color:#fff}
      #kiki-panel .sep{height:1px;background:rgba(255,255,255,.1);margin:4px 8px}
      #kiki-panel .head{padding:9px 12px;font-weight:600;display:flex;justify-content:space-between;align-items:center}
      #kiki-panel .sw{width:38px;height:22px;border-radius:11px;background:#555;position:relative;cursor:pointer;transition:background .15s}
      #kiki-panel .sw.on{background:#e8b45a}
      #kiki-panel .sw::after{content:"";position:absolute;top:3px;left:3px;width:16px;height:16px;border-radius:50%;background:#fff;transition:left .15s}
      #kiki-panel .sw.on::after{left:19px}
      #kiki-panel .note{padding:6px 12px;color:#f0b35a;font-size:12px}
    `;
    document.documentElement.appendChild(s);
  }
  function ensureBar() {
    injectStyle();
    if (bar && document.contains(bar)) { placeBar(); return bar; }
    bar = document.createElement('div');
    bar.id = 'kiki-bar';
    bar.innerHTML = '<div class="kiki-grip">⋯</div><div class="kiki-box"><div class="kiki-tr"></div><div class="kiki-src"></div></div><div class="kiki-note"></div>';
    elTr = bar.querySelector('.kiki-tr'); elSrc = bar.querySelector('.kiki-src'); elNote = bar.querySelector('.kiki-note');
    bindDrag(bar.querySelector('.kiki-grip'));
    placeBar();
    return bar;
  }
  function placeBar() {
    if (!bar) return;
    const overlay = opt.position === 'overlay';
    const mount = overlay ? (site.overlayMount() || site.mountPoint()) : site.mountPoint();
    if (!mount) return;
    bar.className = overlay ? 'kiki-overlay' : 'kiki-below';
    if (!opt.enabled) bar.classList.add('kiki-off');
    if (bar.parentElement !== mount) {
      if (overlay) mount.appendChild(bar); else mount.insertBefore(bar, mount.firstChild);
    }
    applyStyle();
  }
  /// 字幕外观：字号 / 颜色 / 加粗 / 背景 / 模糊 / 描边 / 上下顺序 / 拖动位置
  function applyStyle() {
    if (!bar || !elTr || !elSrc) return;
    const box = bar.querySelector('.kiki-box');
    elTr.style.fontSize = Math.round(opt.size * (opt.trSize / 100)) + 'px';
    elSrc.style.fontSize = Math.max(11, Math.round(opt.size * (opt.srcSize / 100))) + 'px';
    bar.style.setProperty('--kiki-tr-color', opt.trColor);
    bar.style.setProperty('--kiki-src-color', opt.srcColor);
    bar.style.setProperty('--kiki-hi', '#ffffff');
    bar.style.setProperty('--kiki-tr-weight', opt.trBold ? '700' : '400');
    bar.style.setProperty('--kiki-src-weight', opt.srcBold ? '700' : '400');
    bar.style.setProperty('--kiki-bg', String((opt.bgOpacity || 0) / 100));
    bar.style.setProperty('--kiki-shadow', opt.outline === 'shadow' ? '0 2px 6px rgba(0,0,0,.9)' : opt.outline === 'outline' ? '-1px -1px 0 #000,1px -1px 0 #000,-1px 1px 0 #000,1px 1px 0 #000' : 'none');
    if (box) { box.style.backdropFilter = opt.bgBlur ? 'blur(10px)' : 'none'; box.style.webkitBackdropFilter = opt.bgBlur ? 'blur(10px)' : 'none'; }
    // 译文在上还是原文在上
    if (box && elTr && elSrc) {
      const first = opt.trFirst ? elTr : elSrc;
      if (box.firstElementChild !== first) box.insertBefore(first, box.firstElementChild);
    }
    // 拖过就用拖的位置（相对播放器百分比，缩放全屏都不跑偏）
    if (opt.position === 'overlay' && opt.dragX != null && opt.dragY != null) {
      bar.classList.add('kiki-drag');
      bar.style.left = opt.dragX + '%';
      bar.style.top = opt.dragY + '%';
      bar.style.transform = 'translate(-50%, -50%)';
    } else {
      bar.classList.remove('kiki-drag');
      bar.style.left = ''; bar.style.top = ''; bar.style.transform = '';
    }
  }
  /// 抓手拖动：按住上方小条挪字幕
  function bindDrag(grip) {
    if (!grip) return;
    grip.addEventListener('mousedown', (e) => {
      if (retired || !alive()) return retire();
      if (opt.position !== 'overlay') return;
      e.preventDefault(); e.stopPropagation();
      const host = site.overlayMount();
      if (!host) return;
      bar.classList.add('kiki-dragging');
      const move = (ev) => {
        const r = host.getBoundingClientRect();
        const x = ((ev.clientX - r.left) / r.width) * 100;
        const y = ((ev.clientY - r.top) / r.height) * 100;
        opt.dragX = Math.min(95, Math.max(5, x));
        opt.dragY = Math.min(95, Math.max(5, y));
        applyStyle();
      };
      const up = () => {
        document.removeEventListener('mousemove', move, true);
        document.removeEventListener('mouseup', up, true);
        bar.classList.remove('kiki-dragging');
        saveOpt();
      };
      document.addEventListener('mousemove', move, true);
      document.addEventListener('mouseup', up, true);
    });
    grip.addEventListener('dblclick', (e) => { e.stopPropagation(); opt.dragX = null; opt.dragY = null; saveOpt(); applyStyle(); });
  }
  function removeBar() { if (bar) { bar.remove(); bar = null; } lastIdx = -1; }
  let noteTimer = null;
  /// 提示默认 5 秒后自动消失，不挡视线；sticky = true 的（未登录、启动失败）才留着
  function note(msg, sticky) {
    ensureBar();
    if (!elNote) return;
    elNote.textContent = msg || '';
    if (noteTimer) { clearTimeout(noteTimer); noteTimer = null; }
    if (msg && !sticky) noteTimer = setTimeout(() => { if (elNote) elNote.textContent = ''; }, 5000);
  }
  function render(idx) {
    ensureBar();
    if (!opt.enabled) { bar.classList.add('kiki-off'); return; }
    bar.classList.remove('kiki-off');
    const b = state && state.blocks[idx];
    if (!b) { elTr.textContent = ''; elSrc.innerHTML = ''; wordSpans = []; wordBlockIdx = -1; return; }
    const tr = state.tr[idx];
    const showSrc = opt.display !== 'translation';
    const showTr = opt.display !== 'source';
    // 译文还没到就先空着（原文照常滚），到了再补；不摆「…」占位，观感上不会觉得卡（Trancy 同样做法）
    elTr.textContent = showTr ? (tr || '') : b.text;
    elTr.classList.toggle('kiki-wait', false);
    const wantSrc = showTr ? showSrc : false;
    if (!wantSrc) { elSrc.innerHTML = ''; wordSpans = []; wordBlockIdx = -1; return; }
    // 逐词高亮：字幕轨带每个词的时间时把原文拆成 span，播到哪亮到哪（Trancy 式）
    if (opt.karaoke && b.words && b.words.length) {
      if (wordBlockIdx !== idx) {
        elSrc.innerHTML = '';
        wordSpans = []; wordTimes = [];
        for (const w of b.words) {
          const sp = document.createElement('span');
          sp.className = 'kiki-w';
          sp.textContent = w.w;
          elSrc.appendChild(sp);
          wordSpans.push(sp); wordTimes.push(w.t);
        }
        wordBlockIdx = idx;
      }
      highlightWords();
    } else {
      elSrc.textContent = b.text; wordSpans = []; wordBlockIdx = -1;
    }
  }
  /// 按当前播放时间点亮已经说过的词
  function highlightWords() {
    if (!wordSpans.length) return;
    const v = site.videoElement();
    const now = v ? v.currentTime : 0;
    for (let i = 0; i < wordSpans.length; i++) wordSpans[i].classList.toggle('on', wordTimes[i] <= now + 0.05);
  }

  // ---- 播放器控制条里的 Kikishima 按钮与菜单 ----
  function ensureButton() {
    injectStyle();
    const controls = site.controlsMount && site.controlsMount();
    if (!controls) return;
    if (btn && document.contains(btn)) return;
    btn = document.createElement('button');
    btn.className = 'kiki-btn ytp-button' + (opt.enabled ? ' kiki-active' : '');
    btn.title = t().title;
    btn.textContent = '訳';
    btn.addEventListener('click', (e) => { e.stopPropagation(); togglePanel(); });
    controls.insertBefore(btn, controls.firstChild);
  }
  function row(label, valueEl) {
    const r = document.createElement('div'); r.className = 'row';
    const l = document.createElement('span'); l.textContent = label;
    r.appendChild(l); r.appendChild(valueEl);
    return r;
  }
  function buildPanel() {
    const p = document.createElement('div');
    p.id = 'kiki-panel';
    p.addEventListener('click', (e) => e.stopPropagation());
    const head = document.createElement('div'); head.className = 'head';
    const title = document.createElement('span'); title.textContent = t().title;
    const sw = document.createElement('div'); sw.className = 'sw' + (opt.enabled ? ' on' : '');
    sw.addEventListener('click', () => {
      opt.enabled = !opt.enabled; saveOpt();
      sw.classList.toggle('on', opt.enabled);
      if (btn) btn.classList.toggle('kiki-active', opt.enabled);
      render(lastIdx);
      if (opt.enabled) {
        ensureTranslated(Math.max(0, lastIdx));
      }
    });
    head.appendChild(title); head.appendChild(sw);
    p.appendChild(head);
    // app 说扩展旧了：给一行可点的提示（开发者模式装的扩展不会自己更新）
    const mine = chrome.runtime.getManifest().version;
    if (app.wantExtVersion && cmpVer(mine, app.wantExtVersion) < 0) {
      const u = document.createElement('div');
      u.className = 'note';
      u.style.cursor = 'pointer';
      u.textContent = t().update.replace('%v', app.wantExtVersion);
      u.addEventListener('click', () => window.open(app.extDownloadURL || 'https://downloads.kikishima.com/extension/kikishima-chrome.zip', '_blank'));
      p.appendChild(u);
    }
    p.appendChild(Object.assign(document.createElement('div'), { className: 'sep' }));

    const disp = document.createElement('select');
    for (const v of ['both', 'translation', 'source']) {
      const o = document.createElement('option'); o.value = v; o.textContent = t()[v]; if (opt.display === v) o.selected = true; disp.appendChild(o);
    }
    disp.addEventListener('change', () => { opt.display = disp.value; if (opt.display === 'source') cancelPending(); saveOpt(); render(lastIdx); ensureTranslated(Math.max(0, lastIdx)); });
    p.appendChild(row(t().display, disp));

    const tgt = document.createElement('select');
    for (const l of LANGS) {
      const o = document.createElement('option'); o.value = l.code; o.textContent = l.label;
      if (target() === l.code) o.selected = true; tgt.appendChild(o);
    }
    tgt.addEventListener('change', () => {
      cancelPending();
      opt.target = tgt.value; saveOpt();
      if (state) { state.tr = new Array(state.blocks.length); state.done.clear(); state.firstDone = false; loadCache().then(() => { render(lastIdx); ensureTranslated(Math.max(0, lastIdx)); }); }
    });
    p.appendChild(row(t().target, tgt));

    if (state && state.tracks && state.tracks.length > 1) {
      const src = document.createElement('select');
      for (const tk of state.tracks) {
        const o = document.createElement('option'); o.value = tk.lang; o.textContent = tk.name + (tk.kind === 'asr' ? ' (auto)' : '');
        if (state.lang === tk.lang) o.selected = true; src.appendChild(o);
      }
      src.addEventListener('change', async () => {
        opt.sourceLang = src.value;
        await saveOpt();                     // 先落盘：setup() 会重新读偏好，早一步跑就会读回旧值
        currentVideo = null;
        if (panel) { panel.remove(); panel = null; }
        setup();
      });
      p.appendChild(row(t().source_track, src));
    }

    if (state && !(state.tracks && state.tracks.length)) {
      const sp = document.createElement('select');
      const autoOpt = document.createElement('option');
      autoOpt.value = ''; autoOpt.textContent = t().auto + (state.audioLang ? ' · ' + state.audioLang : '');
      if (!opt.spokenLang) autoOpt.selected = true;
      sp.appendChild(autoOpt);
      for (const l of SPOKEN) {
        const o = document.createElement('option'); o.value = l.code; o.textContent = l.label;
        if (opt.spokenLang === l.code) o.selected = true; sp.appendChild(o);
      }
      sp.addEventListener('change', async () => {
        opt.spokenLang = sp.value; saveOpt();
      });
      p.appendChild(row(t().spoken, sp));
      const hint = document.createElement('div'); hint.className = 'note'; hint.textContent = t().spokenHint; p.appendChild(hint);
    }

    const pos = document.createElement('select');
    for (const v of ['overlay', 'below']) {
      const o = document.createElement('option'); o.value = v; o.textContent = t()[v]; if (opt.position === v) o.selected = true; pos.appendChild(o);
    }
    pos.addEventListener('change', () => { opt.position = pos.value; saveOpt(); removeBar(); render(lastIdx); });
    p.appendChild(row(t().position, pos));

    const size = document.createElement('input');
    size.type = 'range'; size.min = '14'; size.max = '40'; size.step = '1'; size.value = String(opt.size);
    size.addEventListener('input', () => { opt.size = parseInt(size.value, 10); saveOpt(); placeBar(); });
    p.appendChild(row(t().size, size));

    const styleBtn = document.createElement('span');
    styleBtn.textContent = '›';
    const styleRow = row(t().style, styleBtn);
    styleRow.style.cursor = 'pointer';
    styleRow.addEventListener('click', () => { panelView = 'style'; rebuildPanel(); });
    p.appendChild(styleRow);

    if (!app.signedIn) {
      const n = document.createElement('div'); n.className = 'note'; n.textContent = t().signIn; p.appendChild(n);
    }
    return p;
  }
  let panelView = 'main';
  function sel(options, value, onChange) {
    const el = document.createElement('select');
    for (const [v, label] of options) {
      const o = document.createElement('option'); o.value = v; o.textContent = label;
      if (String(value) === String(v)) o.selected = true; el.appendChild(o);
    }
    el.addEventListener('change', () => onChange(el.value));
    return el;
  }
  function num(value, min, max, step, onChange) {
    const el = document.createElement('input');
    el.type = 'range'; el.min = String(min); el.max = String(max); el.step = String(step); el.value = String(value);
    el.addEventListener('input', () => onChange(parseInt(el.value, 10)));
    return el;
  }
  function sw(value, onChange) {
    const el = document.createElement('div');
    el.className = 'sw' + (value ? ' on' : '');
    el.addEventListener('click', () => { const v = !el.classList.contains('on'); el.classList.toggle('on', v); onChange(v); });
    return el;
  }
  /// 字幕样式子面板（对齐 Trancy：字号 / 颜色 / 加粗 / 背景 / 模糊 / 描边 / 逐字高亮 / 译文在上）
  function buildStylePanel() {
    const p = document.createElement('div');
    p.id = 'kiki-panel';
    p.addEventListener('click', (e) => e.stopPropagation());
    const head = document.createElement('div'); head.className = 'head';
    const back = document.createElement('span'); back.textContent = '‹ ' + t().back; back.style.cursor = 'pointer';
    back.addEventListener('click', () => { panelView = 'main'; rebuildPanel(); });
    const ttl = document.createElement('span'); ttl.textContent = t().style;
    head.appendChild(back); head.appendChild(ttl);
    p.appendChild(head);
    p.appendChild(Object.assign(document.createElement('div'), { className: 'sep' }));

    const save = () => { saveOpt(); applyStyle(); };
    const COLORS = [['#ffffff', '⚪️'], ['#ffe08a', '🟡'], ['#9fe6a0', '🟢'], ['#9fd0ff', '🔵']];
    p.appendChild(row(t().trSizeL, num(opt.trSize, 60, 160, 5, (v) => { opt.trSize = v; save(); })));
    p.appendChild(row(t().srcSizeL, num(opt.srcSize, 40, 120, 5, (v) => { opt.srcSize = v; save(); })));
    p.appendChild(row(t().colorL, sel(COLORS, opt.trColor, (v) => { opt.trColor = v; save(); })));
    p.appendChild(row(t().boldL, sw(opt.trBold, (v) => { opt.trBold = v; save(); })));
    p.appendChild(row(t().bgL, num(opt.bgOpacity, 0, 90, 5, (v) => { opt.bgOpacity = v; save(); })));
    p.appendChild(row(t().blurL, sw(opt.bgBlur, (v) => { opt.bgBlur = v; save(); })));
    p.appendChild(row(t().outlineL, sel([['none', t().none], ['shadow', t().shadow], ['outline', t().stroke]], opt.outline, (v) => { opt.outline = v; save(); })));
    p.appendChild(row(t().karaokeL, sw(opt.karaoke, (v) => { opt.karaoke = v; save(); wordBlockIdx = -1; render(lastIdx); })));
    p.appendChild(row(t().trFirstL, sw(opt.trFirst, (v) => { opt.trFirst = v; save(); })));
    const rst = document.createElement('span'); rst.textContent = '↺'; rst.style.cursor = 'pointer';
    const rstRow = row(t().reset, rst);
    rstRow.style.cursor = 'pointer';
    rstRow.addEventListener('click', () => { opt.dragX = null; opt.dragY = null; save(); });
    p.appendChild(rstRow);
    return p;
  }
  function rebuildPanel() {
    const host = site.overlayMount() || document.body;
    if (panel) panel.remove();
    panel = panelView === 'style' ? buildStylePanel() : buildPanel();
    host.appendChild(panel);
  }
  function togglePanel() {
    if (panel && document.contains(panel)) { panel.remove(); panel = null; return; }
    panelView = 'main';
    rebuildPanel();
    const close = (e) => {
      if (panel && !panel.contains(e.target) && e.target !== btn) { panel.remove(); panel = null; document.removeEventListener('click', close, true); }
    };
    setTimeout(() => document.addEventListener('click', close, true), 0);
  }

  // ---- 合句 ----
  function groupCues(cues) {
    const blocks = [];
    let cur = null;
    const endsSentence = (x) => /[.!?。！？…]["')\]]?$/.test(x);
    for (const c of cues) {
      if (cur && (c.start - cur.end > 1.5 || cur.text.length >= 90)) { blocks.push(cur); cur = null; }
      if (!cur) cur = { start: c.start, end: c.end, text: c.text, words: (c.words || []).slice() };
      else {
        cur.text += (/[぀-ヿ一-鿿]$/.test(cur.text) ? '' : ' ') + c.text;
        cur.end = c.end;
        if (c.words) cur.words = (cur.words || []).concat(c.words);
      }
      if (endsSentence(cur.text) && cur.text.length >= 20) { blocks.push(cur); cur = null; }
    }
    if (cur) blocks.push(cur);
    return blocks;
  }

  // ---- 翻译 ----
  /// 把区间 [from, to) 送去翻译；服务器是流式的，每行到达就画（不等整批）
  function ownsRequest(job) {
    return state === job.owner && target() === job.target && opt.enabled && opt.display !== 'source' &&
      activeRequests.get(job.requestId) === job;
  }
  function acceptLine(job, i, text) {
    if (!ownsRequest(job) || !Number.isInteger(i) || i < 0 || i >= job.lines.length || typeof text !== 'string' || !text.trim()) return;
    const at = job.from + i;
    if (state.blocks[at]?.text !== job.lines[i]) return;
    state.tr[at] = text;
    if (at === lastIdx) render(lastIdx);
  }
  async function translateRange(from, to, attempt = 0, end = performance.now() + 60000) {
    if (!state || !opt.enabled || opt.display === 'source') return;
    const lines = state.blocks.slice(from, to).map(b => b.text);
    if (!lines.length || performance.now() >= end) return;
    const job = { requestId: crypto.randomUUID(), owner: state, target: target(), lines, from, retryTimer: null };
    activeRequests.set(job.requestId, job);
    const resp = await send({ type: 'translate', requestId: job.requestId, videoId: state.key, trackKey: state.trackKey,
      lines, target: job.target, from, timeoutMs: Math.max(0, Math.floor(end - performance.now())) });
    if (!ownsRequest(job)) return;
    const matches = resp && resp.requestId === job.requestId && resp.videoId === state.key &&
      resp.trackKey === state.trackKey && resp.target === job.target;
    if (matches) (resp.translations || []).forEach((tx, i) => acceptLine(job, i, tx));
    saveCache();
    const completed = new Set();
    for (let i = from; i < to; i++) if (state.tr[i] || state.blocks[i]?.text !== lines[i - from]) completed.add(i);
    const gaps = KikiReliability.missingRanges(from, to, completed);
    if (gaps.length) {
      note(resp?.error ? errorText(resp.error) : t().netError);
      // One automatic missing-line retry, using the original budget. Keep done
      // reservations so playback ticks cannot create an unbounded retry loop.
      if (attempt === 0 && performance.now() + 2000 < end) {
        job.retryTimer = setTimeout(() => {
          if (!ownsRequest(job)) return;
          activeRequests.delete(job.requestId);
          for (const [a, b] of gaps) translateRange(a, b, 1, end);
        }, 2000);
        return;
      }
    } else note('');
    activeRequests.delete(job.requestId);
  }
  /// 保证播放头附近已经翻好：头一块小（快出字），之后成块并行往前铺
  function ensureTranslated(idx) {
    if (!state || !opt.enabled || opt.display === 'source') return;
    const n = state.blocks.length;
    const at = Math.max(0, idx);
    const want = [];
    if (!state.firstDone) {
      state.firstDone = true;
      want.push([at, Math.min(n, at + FIRST_BATCH)]);
      want.push([Math.min(n, at + FIRST_BATCH), Math.min(n, at + FIRST_BATCH + BATCH)]);
    } else {
      const startBlock = Math.floor(at / BATCH) * BATCH;
      want.push([startBlock, Math.min(n, startBlock + BATCH)]);
      want.push([Math.min(n, startBlock + BATCH), Math.min(n, startBlock + BATCH * 2)]);
    }
    for (const [a, b] of want) {
      if (a >= b) continue;
      const reserved = new Set();
      for (let i = a; i < b; i++) if (state.tr[i] || state.done.has(i)) reserved.add(i);
      for (const [from, to] of KikiReliability.missingRanges(a, b, reserved)) {
        for (let i = from; i < to; i++) state.done.add(i);
        translateRange(from, to);   // Only newly missing rows; never overlap an active batch.
      }
    }
  }
  // 服务器逐行流回来：收一条画一条
  try {
    chrome.runtime.onMessage.addListener((msg) => {
      if (!msg || msg.type !== 'batchLine' || !state) return;
      const job = activeRequests.get(msg.requestId);
      if (!job || msg.videoId !== job.owner.key || msg.trackKey !== job.owner.trackKey || msg.target !== job.target || msg.from !== job.from) return;
      acceptLine(job, msg.i, msg.t);
    });
  } catch (e) { /* 非扩展环境 */ }

  // ---- 播放同步 ----
  function findIdx(tm) {
    const bs = state.blocks;
    let lo = 0, hi = bs.length - 1, ans = -1;
    while (lo <= hi) { const m = (lo + hi) >> 1; if (bs[m].start <= tm) { ans = m; lo = m + 1; } else hi = m - 1; }
    if (ans < 0) return -1;
    return tm <= bs[ans].end + 0.8 ? ans : -1;
  }
  function onTime() {
    const v = site.videoElement();
    if (!v || !state) return;
    const idx = findIdx(v.currentTime);
    if (idx !== lastIdx) { lastIdx = idx; render(idx); }
    else highlightWords();
    if (idx >= 0) ensureTranslated(idx);
  }
  function onSeek() {
    const video = site.videoElement();
    const at = state && video ? Math.max(0, findIdx(video.currentTime)) : 0;
    const start = Math.floor(at / BATCH) * BATCH;
    cancelPending(job => job.from + job.lines.length <= start || job.from >= start + BATCH * 2);
    onTime();
  }
  function bindVideo() {
    const v = site.videoElement();
    if (!v || timeBound === v) return;
    if (timeBound) { timeBound.removeEventListener('timeupdate', onTime); timeBound.removeEventListener('seeking', onSeek); }
    timeBound = v;
    v.addEventListener('timeupdate', onTime);
    v.addEventListener('seeking', onSeek);
  }

  // ---- 入口 ----
  async function setup() {
    if (!site.isVideoPage()) { teardown(); return; }
    const key = site.videoKey();
    if (key === currentVideo) { ensureButton(); return; }
    teardown();
    currentVideo = key;
    const generation = setupGeneration;
    const options = await loadOpt();
    if (generation !== setupGeneration) return;
    opt = options;
    ensureButton();
    ensureBar();
    note(t().loading);

    const hello = await send({ type: 'hello' });
    if (generation !== setupGeneration) return;
    if (hello && !hello.error) {
      app = { signedIn: !!hello.signedIn, ui: KikiReliability.uiLanguage(hello.ui), plan: hello.plan || '' };
      if (typeof hello.enabled === 'boolean') opt.enabled = hello.enabled;   // 总开关在弹窗里，以它为准
    }

    let got;
    try { got = await site.getCues(opt.sourceLang); } catch (e) { got = { cues: [], reason: 'fetch_failed' }; }
    if (generation !== setupGeneration || currentVideo !== key) return;

    if (got.cues && got.cues.length) {
      const blocks = groupCues(got.cues);
      const tracks = got.tracks || [];
      const selectedTrack = tracks.find((track) => track.lang === got.lang) || null;
      const trackKey = KikiReliability.trackIdentity(selectedTrack, blocks);
      state = { key, trackKey, blocks, tr: new Array(blocks.length), done: new Set(), firstDone: false, tracks, lang: got.lang, live: false };
      await loadCache();   // 这个视频翻过就直接用，重看/回放瞬间出字
      if (generation !== setupGeneration) return;
      state.audioLang = got.audioLang || got.lang || '';
      state.title = got.title || '';
      note(opt.enabled && !app.signedIn ? t().signIn : '', true);
      send({ type: 'active', on: opt.enabled, videoId: key, title: got.title || '', lang: got.lang || '', site: site.name });
      bindVideo(); onTime();
      if (opt.enabled) ensureTranslated(0);
      return;
    }

    // 轨道存在但接口内容为空：读取播放器已经渲染的字幕作为兜底，仍由扩展自己翻译
    if (got && got.reason === 'fetch_failed' && typeof site.startLive === 'function') {
      state = {
        key, trackKey: KikiReliability.trackIdentity(null, []), blocks: [], tr: [], done: new Set(), firstDone: true,
        tracks: got.tracks || [], lang: got.lang || '', audioLang: got.audioLang || '', title: got.title || '', live: true,
      };
      note('');
      send({ type: 'active', on: opt.enabled, videoId: key, title: got.title || '', lang: got.lang || '', site: site.name });
      state.stopLive = site.startLive((cue) => {
        if (generation !== setupGeneration || !state || state.key !== key) return;
        const last = state.blocks[state.blocks.length - 1];
        if (last && cue.text.startsWith(last.text)) {
          const index = state.blocks.length - 1;
          cancelPending(job => job.from <= index && index < job.from + job.lines.length);
          last.text = cue.text;
          last.end = cue.end;
          const at = state.blocks.length - 1;
          state.tr[at] = undefined;
          state.done.delete(at);
        } else {
          state.blocks.push({ ...cue });
          state.tr.push(undefined);
        }
        lastIdx = state.blocks.length - 1;
        render(lastIdx);
        if (opt.enabled) ensureTranslated(lastIdx);
      });
      bindVideo();
      return;
    }

    // 真的没有字幕轨：这里只提示，不去动 Mac app（app 独立运行，网页不指挥它）
    state = null;
    console.warn('[Kikishima] no captions, reason =', got && got.reason);
    note(t().noTrack, true);
  }

  // （实时听译已归 Mac app 自己管，扩展不再遥控它）
  function teardown() {
    setupGeneration++;
    cancelPending();
    if (currentVideo) send({ type: 'active', on: false, videoId: currentVideo });
    if (state && state.stopLive) state.stopLive();
    currentVideo = null; state = null; removeBar();
    if (panel) { panel.remove(); panel = null; }
    if (timeBound) { timeBound.removeEventListener('timeupdate', onTime); timeBound.removeEventListener('seeking', onSeek); timeBound = null; }
  }

  // 扩展被重新加载后，旧标签页里的这份脚本就成了孤儿：所有 chrome.* 抛 "Extension context invalidated"
  // 检测到就自己收摊（撤掉字幕条与按钮、停掉轮询），等页面刷新时新脚本接手
  const alive = () => { try { return !!(chrome.runtime && chrome.runtime.id); } catch (e) { return false; } };
  let retired = false;
  function retire() {
    if (retired) return; retired = true;
    try { teardown(); } catch (e) {}
    try { if (btn) { btn.remove(); btn = null; } } catch (e) {}
    clearInterval(navTimer); clearInterval(fixTimer);
  }

  // 弹窗里改了开关 / 登录 / 语言：重新走一遍
  try {
    chrome.runtime.onMessage.addListener((msg) => {
      if (!msg || msg.type !== 'settingsChanged') return;
      currentVideo = null;
      setup();
    });
  } catch (e) { /* 非扩展环境 */ }

  for (const evt of site.navEvents || []) window.addEventListener(evt, () => setTimeout(setup, 400));
  let lastHref = location.href;
  const navTimer = setInterval(() => {
    if (!alive()) return retire();
    if (location.href !== lastHref) { lastHref = location.href; setup(); }
  }, 1000);
  // 播放器控制条会被 YouTube 重建：按钮丢了补回来，字幕条位置也跟着修
  const fixTimer = setInterval(() => {
    if (!alive()) return retire();
    if (site.isVideoPage()) { ensureButton(); if (state) placeBar(); }
  }, 2000);
  setTimeout(setup, 600);
})();
