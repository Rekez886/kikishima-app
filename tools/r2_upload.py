#!/usr/bin/env python3
# 把文件上传到 Cloudflare R2（S3 兼容接口，AWS SigV4，纯标准库，不依赖 aws cli）
# 凭证：~/Library/Application Support/Kikishima/r2.env（R2_ENDPOINT / R2_KEY / R2_SECRET，chmod 600，不进仓库）
# 用法：python3 tools/r2_upload.py <bucket> <本地文件> [<对象名>] [--type MIME]
import sys, os, hashlib, hmac, datetime, urllib.request, urllib.parse, mimetypes

def load_env():
    p = os.path.expanduser("~/Library/Application Support/Kikishima/r2.env")
    env = {}
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1); env[k.strip()] = v.strip()
    for k in ("R2_ENDPOINT", "R2_KEY", "R2_SECRET"):
        if not env.get(k): sys.exit(f"r2.env 缺 {k}")
    return env

def sign(key, msg): return hmac.new(key, msg.encode(), hashlib.sha256).digest()

def upload(bucket, path, key, ctype=None):
    env = load_env()
    endpoint = env["R2_ENDPOINT"].rstrip("/")
    if not endpoint.startswith("http"): endpoint = "https://" + endpoint
    host = urllib.parse.urlparse(endpoint).netloc
    data = open(path, "rb").read()
    ctype = ctype or mimetypes.guess_type(key)[0] or "application/octet-stream"
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ"); date = now.strftime("%Y%m%d")
    region, service = "auto", "s3"
    canonical_uri = "/" + bucket + "/" + urllib.parse.quote(key, safe="/-_.~")
    payload_hash = hashlib.sha256(data).hexdigest()
    headers = {"host": host, "x-amz-content-sha256": payload_hash, "x-amz-date": amz_date, "content-type": ctype}
    signed = ";".join(sorted(headers))
    canonical_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted(headers))
    creq = "\n".join(["PUT", canonical_uri, "", canonical_headers, signed, payload_hash])
    scope = f"{date}/{region}/{service}/aws4_request"
    sts = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(creq.encode()).hexdigest()])
    k = sign(("AWS4" + env["R2_SECRET"]).encode(), date); k = sign(k, region); k = sign(k, service); k = sign(k, "aws4_request")
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    auth = f"AWS4-HMAC-SHA256 Credential={env['R2_KEY']}/{scope}, SignedHeaders={signed}, Signature={sig}"
    req = urllib.request.Request(endpoint + canonical_uri, data=data, method="PUT",
                                 headers={**{k: v for k, v in headers.items() if k != "host"}, "Authorization": auth,
                                          "Cache-Control": "public, max-age=300" if (key.endswith(".xml") or key.endswith(".zip") or key.endswith(".html")) else "public, max-age=31536000"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.status

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    ctype = None
    if "--type" in sys.argv: ctype = sys.argv[sys.argv.index("--type") + 1]; args = [a for a in args if a != ctype]
    if len(args) < 2: sys.exit(__doc__ or "usage: r2_upload.py <bucket> <file> [<key>]")
    bucket, path = args[0], args[1]
    key = args[2] if len(args) > 2 else os.path.basename(path)
    try:
        print(f"uploaded {key} → {upload(bucket, path, key, ctype)}")
    except urllib.error.HTTPError as e:
        sys.exit(f"upload failed {e.code}: {e.read()[:300]}")
