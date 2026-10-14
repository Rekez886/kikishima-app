# Kikishima（Chrome 扩展）

看网页视频时读取视频自带的字幕轨、提前翻译，把双语字幕贴在视频下方，与播放同步。目前支持 YouTube；加新站点只要写一个 `sites/<站点>.js`（实现 `window.KikiSite`）并在 manifest 的 `content_scripts` 加 matches。

扩展本身不登录、不存密钥：翻译请求经 Chrome 原生消息通道交给本机 Kikishima app（账号、额度、术语表都在 app 里）。

## 开发者模式安装
1. `chrome://extensions` → 右上角开「开发者模式」
2. 「加载已解压的扩展程序」→ 选这个文件夹
3. 先启动过一次 Kikishima app（它会写宿主清单 `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.kikishima.host.json`）

开发者模式的固定 ID：`gekennmfdgkinclbjmnaembfcjoepplk`（manifest 的 `key` 决定）。上架商店后商店会另给一个 ID，app 的白名单同时认两个（见 `Sources/Kikishima/NativeHost.swift`）。

## 文件
- `manifest.json` MV3
- `sites/youtube-main.js` 页面主世界：交出播放器的字幕轨列表
- `sites/youtube.js` 站点适配器：选轨、取轨、挂载点、导航事件
- `content.js` 合句、按播放进度提前翻译、渲染双语条（站点无关）
- `background.js` 与 app 的原生消息桥；装好 / 浏览器启动即打一次招呼
