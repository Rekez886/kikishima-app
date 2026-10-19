#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .build/sidebar-preview
python3 - <<'PYCODE'
from pathlib import Path
source = Path('Sources/Kikishima/MainWindow.swift').read_text()
def block(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
Path('.build/sidebar-preview/NavigationFixture.swift').write_text('import SwiftUI\n' +
    block('enum MainSection:') + '\n' + block('struct SidebarNavigation:'))
PYCODE
swiftc -parse-as-library -module-cache-path /tmp/kikishima-preview-cache \
  Sources/Kikishima/DesignTokens.swift Sources/Kikishima/BrandIcons.swift \
  Sources/Kikishima/SidebarAccountCard.swift .build/sidebar-preview/NavigationFixture.swift tools/sidebar_preview/main.swift \
  -o .build/sidebar-preview/render
.build/sidebar-preview/render
