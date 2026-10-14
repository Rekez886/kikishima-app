"""Summarize local numeric diagnostics without reading transcripts or credentials."""
import json
import math
import statistics
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("未采到已结束的翻译请求。请确认登录后开始字幕并播放测试内容。")
    raise SystemExit(0)
rows = json.loads(path.read_text())
successful = [row for row in rows if row["succeeded"]]
print(f"请求结束样本 {len(rows)}，成功 {len(successful)}，失败 {len(rows) - len(successful)}（不含退出时取消的请求）")
calibrated = bool(rows) and all(row.get("measurementVersion") == 2 for row in rows)
pending_label = "本块最早保留字符出现到切块" if calibrated else "旧口径待翻累计等待（估计，不与新版直接比较）"
for key, label in [("pendingAgeMs", pending_label), ("queueMs", "切块到本次请求（重试含之前等待）"),
                   ("requestToFirstMs", "本次请求到首字更新"), ("chunkToFirstMs", "切块到首字更新"),
                   ("requestToEndMs", "本次请求到全文完成")]:
    values = sorted(row[key] for row in successful if row.get(key) is not None)
    if values:
        print(f"{label}: 中位数 {statistics.median(values):.0f} ms，P95 {values[math.ceil(len(values)*.95)-1]} ms，样本 {len(values)}")
print("首字指主线程收到非空译文并更新状态，不是屏幕绘制时间；请求耗时包含客户端调度、网络、服务器和模型。")
print("新版按当前保留字符的观察时间计时；修订保留共同前缀、改写部分重新计时。不是声音到字幕耗时。" if calibrated else "旧版按同一待翻批次最早出现时间估计，剩余文本可能偏大。")
print("未记录语音识别前耗时；暂停或切换语言强制收尾的块可能没有待翻计时。")
print("最多保留本次进程前 1000 个结束请求。样本少时 P95 不稳定；不能单凭成功请求判断总体可靠性。")
