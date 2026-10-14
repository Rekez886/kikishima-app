// 扩展弹窗：自己的登录与账号状态（与 Mac app 同一个账号，服务器是同一套）
const API = 'https://api.kikishima.com';
const S = {
  'zh-Hans': { signIn: '登录', email: '邮箱', send: '发送验证码', sending: '发送中…', code: '6 位验证码', verify: '登录',
    signedIn: '已登录', signOut: '退出登录', free: '免费版', pro: 'Pro', left: '本周剩余约 %m 分钟', month: '本月已用约 %m 分钟',
    hintOn: '在 YouTube 上会自动显示双语字幕', hintOff: '已关闭；打开后在 YouTube 上显示双语字幕',
    resend: '重新发送', changeEmail: '换个邮箱', needSignIn: '登录后即可在网页上使用', upgrade: '升级 Pro',
    google: '使用 Google 登录', apple: '通过 Apple 登录', orEmail: '或用邮箱验证码', failed: '登录失败，请重试' },
  'zh-Hant': { signIn: '登入', email: '電子郵件', send: '傳送驗證碼', sending: '傳送中…', code: '6 位驗證碼', verify: '登入',
    signedIn: '已登入', signOut: '登出', free: '免費版', pro: 'Pro', left: '本週剩餘約 %m 分鐘', month: '本月已使用約 %m 分鐘',
    hintOn: '會在 YouTube 顯示雙語字幕', hintOff: '已關閉；開啟後會在 YouTube 顯示雙語字幕',
    resend: '重新傳送', changeEmail: '更換電子郵件', needSignIn: '登入後即可在網頁上使用', upgrade: '升級 Pro',
    google: '使用 Google 登入', apple: '使用 Apple 登入', orEmail: '或使用電子郵件驗證碼', failed: '登入失敗，請再試一次' },
  ja: { signIn: 'ログイン', email: 'メールアドレス', send: '確認コードを送る', sending: '送信中…', code: '6桁のコード', verify: 'ログイン',
    signedIn: 'ログイン済み', signOut: 'ログアウト', free: '無料プラン', pro: 'Pro', left: '今週の残り約 %m 分', month: '今月 約 %m 分使用',
    hintOn: 'YouTubeで二言語字幕を表示します', hintOff: 'オフです。オンにするとYouTubeで字幕を表示します',
    resend: '再送信', changeEmail: 'メールを変更', needSignIn: 'ログインするとウェブで使えます', upgrade: 'Proにする',
    google: 'Googleでログイン', apple: 'Appleでサインイン', orEmail: 'またはメールの確認コード', failed: 'ログインに失敗しました' },
  en: { signIn: 'Sign in', email: 'Email', send: 'Send code', sending: 'Sending…', code: '6-digit code', verify: 'Sign in',
    signedIn: 'Signed in', signOut: 'Sign out', free: 'Free', pro: 'Pro', left: 'about %m min left this week', month: 'about %m min used this month',
    hintOn: 'Bilingual captions show up on YouTube', hintOff: 'Off. Turn it on for captions on YouTube',
    resend: 'Resend', changeEmail: 'Change email', needSignIn: 'Sign in to use it on the web', upgrade: 'Upgrade to Pro',
    google: 'Sign in with Google', apple: 'Sign in with Apple', orEmail: 'or use an email code', failed: 'Sign-in failed, try again' },
  ko: { signIn: '로그인', email: '이메일', send: '인증 코드 보내기', sending: '보내는 중…', code: '6자리 인증 코드', verify: '로그인',
    signedIn: '로그인됨', signOut: '로그아웃', free: '무료', pro: 'Pro', left: '이번 주 약 %m분 남음', month: '이번 달 약 %m분 사용',
    hintOn: 'YouTube에 이중 언어 자막을 표시합니다', hintOff: '꺼짐. 켜면 YouTube에 자막을 표시합니다',
    resend: '다시 보내기', changeEmail: '이메일 변경', needSignIn: '로그인하면 웹에서 사용할 수 있습니다', upgrade: 'Pro로 업그레이드',
    google: 'Google로 로그인', apple: 'Apple로 로그인', orEmail: '또는 이메일 인증 코드 사용', failed: '로그인에 실패했습니다. 다시 시도하세요' },
};
const t = S[KikiReliability.uiLanguage(navigator.language)] || S.en;

const get = (keys) => new Promise((r) => chrome.storage.local.get(keys, (v) => r(v || {})));
const set = (obj) => new Promise((r) => chrome.storage.local.set(obj, () => r()));

async function api(path, body, token) {
  const res = await fetch(API + path, {
    method: body ? 'POST' : 'GET',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: 'Bearer ' + token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json.error || ('http_' + res.status));
  return json;
}

function make(tag, props, children) {
  const n = document.createElement(tag);
  Object.assign(n, props || {});
  for (const c of children || []) n.appendChild(c);
  return n;
}

async function render() {
  const { session, accountEmail, plan, usage, enabled = false, codeSent, authError } = await get(['session', 'accountEmail', 'plan', 'usage', 'enabled', 'codeSent', 'authError']);
  const acc = document.getElementById('account');
  const hint = document.getElementById('hint');
  const toggle = document.getElementById('toggle');
  acc.innerHTML = '';
  toggle.classList.toggle('on', !!enabled);
  hint.textContent = enabled ? t.hintOn : t.hintOff;

  if (session) {
    const rowTop = make('div', { className: 'row' }, [
      make('strong', { textContent: plan === 'pro' ? t.pro : t.free }),
      make('button', { className: 'ghost', textContent: t.signOut, onclick: async () => { await set({ session: '', plan: '', usage: null }); render(); } }),
    ]);
    acc.appendChild(rowTop);
    acc.appendChild(make('div', { className: 'muted', textContent: accountEmail || '' }));
    if (usage && usage.quota > 0) {
      const mins = Math.max(0, Math.round((usage.quota - usage.tokens) / 4000));
      const used = Math.round(usage.tokens / 4000);
      acc.appendChild(make('div', { className: 'muted', textContent: (plan === 'pro' ? t.month.replace('%m', used) : t.left.replace('%m', mins)) }));
    }
    if (plan !== 'pro') {
      acc.appendChild(make('div', { className: 'row' }, [
        make('a', { href: 'https://buy.polar.sh/polar_cl_5YfqHr8odzwwxcyVuttv1KGCdDrT82PgloJ6q41aKkh' + (accountEmail ? '?customer_email=' + encodeURIComponent(accountEmail) : ''), target: '_blank', textContent: t.upgrade }),
      ]));
    }
    return;
  }

  acc.appendChild(make('div', { className: 'muted', textContent: t.needSignIn }));

  // Google / Apple：交给 service worker 发起 —— 弹窗一失焦就被销毁，回调必须落在后台
  const oauth = (provider) => async () => {
    const btns = acc.querySelectorAll('button'); btns.forEach((b) => (b.disabled = true));
    await set({ authError: '' });
    chrome.runtime.sendMessage({ type: 'oauth', provider }, (r) => {
      void chrome.runtime.lastError;   // 弹窗已关就收不到，状态靠 storage
      if (r && r.ok) { refreshUsage(); }
      render();
    });
  };
  acc.appendChild(make('div', { className: 'row' }, [
    make('button', { textContent: t.google, onclick: oauth('google'), style: 'flex:1' }),
    make('button', { className: 'ghost', textContent: t.apple, onclick: oauth('apple'), style: 'flex:1' }),
  ]));
  if (authError) acc.appendChild(make('div', { className: 'warn', textContent: t.failed + '（' + authError + '）' }));
  acc.appendChild(make('div', { className: 'muted', textContent: t.orEmail, style: 'margin-top:6px' }));
  if (!codeSent) {
    const input = make('input', { type: 'email', placeholder: t.email, value: accountEmail || '' });
    const btn = make('button', { textContent: t.send });
    btn.onclick = async () => {
      const email = input.value.trim();
      if (!email.includes('@')) return;
      btn.disabled = true; btn.textContent = t.sending;
      try {
        await api('/auth/email/start', { email });
        await set({ accountEmail: email, codeSent: true });
        render();
      } catch (e) {
        btn.disabled = false; btn.textContent = t.send;
        acc.appendChild(make('div', { className: 'warn', textContent: String(e.message) }));
      }
    };
    acc.appendChild(make('div', { className: 'row' }, [input, btn]));
  } else {
    const input = make('input', { placeholder: t.code, inputMode: 'numeric' });
    const btn = make('button', { textContent: t.verify });
    btn.onclick = async () => {
      const code = input.value.replace(/\D/g, '');
      if (code.length !== 6) return;
      btn.disabled = true;
      try {
        const r = await api('/auth/email/verify', { email: accountEmail, code, device: 'Chrome' });
        await set({ session: r.session, plan: r.plan, accountEmail: r.email || accountEmail, codeSent: false, enabled: true });
        refreshUsage();
        render();
      } catch (e) {
        btn.disabled = false;
        acc.appendChild(make('div', { className: 'warn', textContent: String(e.message) }));
      }
    };
    acc.appendChild(make('div', { className: 'row' }, [input, btn]));
    acc.appendChild(make('div', { className: 'row' }, [
      make('button', { className: 'ghost', textContent: t.changeEmail, onclick: async () => { await set({ codeSent: false }); render(); } }),
      make('button', { className: 'ghost', textContent: t.resend, onclick: async () => {
        try { await api('/auth/email/start', { email: accountEmail }); await set({ authError: '' }); }
        catch (e) { await set({ authError: String(e.message) }); }
        render();
      } }),
    ]));
  }
}

async function refreshUsage() {
  const { session } = await get(['session']);
  if (!session) return;
  try {
    const me = await api('/me', null, session);
    await set({ plan: me.plan, usage: { tokens: me.tokens, quota: me.quota }, accountEmail: me.email || undefined });
    render();
  } catch (e) {
    if (String(e.message) === 'unauthorized') { await set({ session: '', plan: '' }); render(); }
  }
}

document.getElementById('toggle').onclick = async () => {
  const { enabled = false } = await get(['enabled']);
  await set({ enabled: !enabled });
  render();
};
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && ('session' in changes || 'authError' in changes || 'plan' in changes)) render();
});
render();
refreshUsage();
