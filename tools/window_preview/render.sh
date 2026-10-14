#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .build/window-preview
python3 - <<'PY'
s = open('Sources/Kikishima/MainWindow.swift').read().split('// MARK: - 记录')[0]
s = s.replace('import Speech', '')
open('.build/window-preview/WindowViews.swift', 'w').write(s)
PY
swiftc -parse-as-library Sources/Kikishima/BrandIcons.swift Sources/Kikishima/SidebarAccountCard.swift Sources/Kikishima/HomeCaptionPreview.swift Sources/Kikishima/CaptionPreviewText.swift .build/window-preview/WindowViews.swift tools/window_preview/fixtures.swift tools/window_preview/main.swift -o .build/window-preview/render
for lang in zh-Hans en ja ko zh-Hant; do
    for theme in light dark; do
        tier=free
        if [[ "$lang" == "en" ]]; then tier=signedOut; fi
        if [[ "$lang" == "ja" ]]; then tier=pro; fi
        KIKISHIMA_PREVIEW_CASE="$lang $tier $theme" .build/window-preview/render
    done
done
