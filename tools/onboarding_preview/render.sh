#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .build/onboarding-preview
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/Kikishima/Onboarding.swift').read_text()
status = source[source.index('enum PermissionStatus'):source.index('struct PermissionsPage:')]
row = source[source.index('struct PermissionRow:'):source.index('// MARK: - 语言页')]
Path('.build/onboarding-preview/PermissionFixture.swift').write_text('import SwiftUI\n' + status + row)
PY
swiftc -parse-as-library -module-cache-path /tmp/kikishima-preview-cache \
  Sources/Kikishima/DesignTokens.swift Sources/Kikishima/BrandIcons.swift \
  Sources/Kikishima/OnboardingComponents.swift Sources/Kikishima/HomeCaptionPreview.swift \
  .build/onboarding-preview/PermissionFixture.swift tools/onboarding_preview/main.swift \
  -o .build/onboarding-preview/render
.build/onboarding-preview/render
