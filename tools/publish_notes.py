#!/usr/bin/env python3
# 更新说明按语言发布：dist/notes-<ver>.<lang>.md（lang = zh-Hans / zh-Hant / ja / en / ko）→ HTML 上传 R2 notes/<ver>.<lang>.html
# → 往 dist/appcast.xml 对应版本的 <item> 里写 <sparkle:releaseNotesLink xml:lang="…">，Sparkle 按用户系统语言挑；en 作默认
# 更新说明：纯修复版只写「修复了一些问题」；带功能的版本要把用户看得见的变化列出来，不写内部细节
# 用法：python3 tools/publish_notes.py 0.11            （release.sh 会自动调；也可事后补）
import sys, os, re, html, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LANGS = ["zh-Hans", "zh-Hant", "ja", "en", "ko"]
BASE = "https://downloads.kikishima.com"

def md_to_html(md: str, lang: str) -> str:
    lines, out, in_list = md.splitlines(), [], False
    for raw in lines:
        l = raw.rstrip()
        if l.startswith("- "):
            if not in_list: out.append("<ul>"); in_list = True
            out.append(f"<li>{html.escape(l[2:].strip())}</li>")
            continue
        if in_list: out.append("</ul>"); in_list = False
        if l.startswith("## "): out.append(f"<h3>{html.escape(l[3:].strip())}</h3>")
        elif l.startswith("# "): out.append(f"<h2>{html.escape(l[2:].strip())}</h2>")
        elif l: out.append(f"<p>{html.escape(l)}</p>")
    if in_list: out.append("</ul>")
    body = "\n".join(out)
    return (f'<!doctype html><html lang="{lang}"><head><meta charset="utf-8">'
            '<style>body{font-family:-apple-system,"Hiragino Sans","PingFang SC",sans-serif;font-size:13px;line-height:1.55;margin:12px 16px;color:#222}'
            '@media (prefers-color-scheme: dark){body{color:#ddd;background:#1e1e1e}}h2,h3{font-size:14px;margin:0 0 8px}ul{padding-left:18px;margin:6px 0}li{margin:3px 0}</style>'
            f'</head><body>{body}</body></html>')

def upload(path: str, key: str, ctype: str):
    subprocess.run([sys.executable, os.path.join(HERE, "r2_upload.py"), "kikishima-downloads", path, key, "--type", ctype], check=True)

def main():
    ver = sys.argv[1]
    dist = os.path.join(ROOT, "dist")
    found = []
    for lang in LANGS:
        src = os.path.join(dist, f"notes-{ver}.{lang}.md")
        if not os.path.exists(src): continue
        out = os.path.join(dist, f"notes-{ver}.{lang}.html")
        open(out, "w", encoding="utf-8").write(md_to_html(open(src, encoding="utf-8").read(), lang))
        upload(out, f"notes/{ver}.{lang}.html", "text/html; charset=utf-8")
        found.append(lang)
    if not found:
        print(f"notes: 没有 dist/notes-{ver}.<lang>.md，appcast 只用 <description>"); return
    appcast = os.path.join(dist, "appcast.xml")
    xml = open(appcast, encoding="utf-8").read()
    m = re.search(rf"<item>(?:(?!</item>).)*?<sparkle:shortVersionString>{re.escape(ver)}</sparkle:shortVersionString>.*?</item>", xml, re.S)
    if not m: sys.exit(f"appcast 里没有 {ver} 的 item")
    item = m.group(0)
    item = re.sub(r"\s*<sparkle:releaseNotesLink[^>]*>.*?</sparkle:releaseNotesLink>", "", item, flags=re.S)
    links = []
    default = "en" if "en" in found else found[0]
    links.append(f"      <sparkle:releaseNotesLink>{BASE}/notes/{ver}.{default}.html</sparkle:releaseNotesLink>")
    for lang in found:
        links.append(f'      <sparkle:releaseNotesLink xml:lang="{lang}">{BASE}/notes/{ver}.{lang}.html</sparkle:releaseNotesLink>')
    # 放在 <description> 前；旧客户端 / 不支持的场景仍回落到 description
    item = item.replace("      <description>", "\n".join(links) + "\n      <description>", 1)
    xml = xml.replace(m.group(0), item, 1)
    open(appcast, "w", encoding="utf-8").write(xml)
    upload(appcast, "appcast.xml", "application/xml")
    print(f"notes: {ver} → {', '.join(found)}（默认 {default}），appcast 已更新")

if __name__ == "__main__":
    main()
