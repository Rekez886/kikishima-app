#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -x Kikishima >/dev/null; then
    echo '请先退出 Kikishima，再重新打开这个文件。'
    read -r -p '按回车关闭。' ignored
    exit 1
fi
test -x build/Kikishima.app/Contents/MacOS/Kikishima
report_dir=$(mktemp -d /tmp/kikishima-timing.XXXXXX)
echo '请开始字幕，播放几分钟虚构会议内容。停止后，从菜单栏退出 Kikishima。'
echo "本地诊断报告位置：$report_dir/timing.json"
# LaunchServices gives the app its own permission identity, unlike executing
# Contents/MacOS directly as a terminal child. -W retains report-on-exit behavior.
/usr/bin/open -W -n --env "KIKISHIMA_TIMING_OUTPUT=$report_dir/timing.json" "$PWD/build/Kikishima.app"
python3 tools/report_translation_timing.py "$report_dir/timing.json"
read -r -p '按回车关闭。' ignored
