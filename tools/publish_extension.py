#!/usr/bin/env python3
# 把 chrome-extension/ 打包上传到 Chrome 网上应用店并发布（用官方 API，纯标准库）
# 凭证：~/Library/Application Support/Kikishima/chrome-store.env（chmod 600，不进仓库）
#   CWS_CLIENT_ID=...          Google Cloud OAuth 客户端（类型：桌面应用）
#   CWS_CLIENT_SECRET=...
#   CWS_REFRESH_TOKEN=...      通过 Google OAuth 一次性授权获取，用于刷新访问令牌
#   CWS_ITEM_ID=...            第一次在开发者后台手动上传后得到的商品 ID
# 用法：python3 tools/publish_extension.py [--draft]     （默认上传后直接发布）
import json, os, ssl, sys, urllib.request, urllib.parse, zipfile, io

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV = os.path.expanduser("~/Library/Application Support/Kikishima/chrome-store.env")
FILES = ["manifest.json", "background.js", "content.js", "README.md"]
DIRS = ["sites"]

def load_env():
    if not os.path.exists(ENV):
        sys.exit(f"没有 {ENV}：请先通过 Google OAuth 获取 refresh token")
    env = {}
    for line in open(ENV, encoding="utf-8"):
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1); env[k.strip()] = v.strip()
    for k in ("CWS_CLIENT_ID", "CWS_CLIENT_SECRET", "CWS_REFRESH_TOKEN", "CWS_ITEM_ID"):
        if not env.get(k): sys.exit(f"chrome-store.env 缺 {k}")
    return env

def access_token(env):
    data = urllib.parse.urlencode({
        "client_id": env["CWS_CLIENT_ID"], "client_secret": env["CWS_CLIENT_SECRET"],
        "refresh_token": env["CWS_REFRESH_TOKEN"], "grant_type": "refresh_token",
    }).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["access_token"]

def build_zip() -> bytes:
    buf = io.BytesIO()
    src = os.path.join(ROOT, "chrome-extension")
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for f in FILES:
            p = os.path.join(src, f)
            if os.path.exists(p): z.write(p, f)
        for d in DIRS:
            base = os.path.join(src, d)
            for root, _, names in os.walk(base):
                for n in names:
                    p = os.path.join(root, n)
                    z.write(p, os.path.relpath(p, src))
    return buf.getvalue()

def call(url, token, method="POST", body=None, ctype=None):
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("x-goog-api-version", "2")
    if ctype: req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url} → {e.code}: {e.read().decode()[:400]}")

def main():
    env = load_env()
    item = env["CWS_ITEM_ID"]
    token = access_token(env)
    pkg = build_zip()
    ver = json.loads(open(os.path.join(ROOT, "chrome-extension/manifest.json"), encoding="utf-8").read())["version"]
    up = call(f"https://www.googleapis.com/upload/chromewebstore/v1.1/items/{item}", token, "PUT", pkg, "application/zip")
    state = up.get("uploadState")
    if state not in ("SUCCESS", "IN_PROGRESS"):
        sys.exit(f"上传失败：{json.dumps(up, ensure_ascii=False)[:400]}")
    print(f"uploaded extension {ver} → {state}")
    if "--draft" in sys.argv:
        print("已上传为草稿（未发布）"); return
    pub = call(f"https://www.googleapis.com/chromewebstore/v1.1/items/{item}/publish", token, "POST", b"", "application/json")
    print("publish:", ",".join(pub.get("status", [])) or json.dumps(pub, ensure_ascii=False)[:200])
    print("提交审核完成；通过后所有用户几小时内自动更新")

if __name__ == "__main__":
    main()
