#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
python3 Resources/l10n/gen.py --check
python3 tests/copy_feedback/check_wiring.py
swiftc Sources/Kikishima/CopyFeedback.swift tests/copy_feedback/main.swift -o "$KK_TEST_TMP_ROOT/copy-feedback"
"$KK_TEST_TMP_ROOT/copy-feedback"
swiftc -frontend -parse Sources/Kikishima/CaptionPanel.swift Sources/Kikishima/CaptionReview.swift Sources/Kikishima/CopyFeedbackView.swift
cat > "$KK_TEST_TMP_ROOT/UIStubs.swift" <<'SWIFT'
import SwiftUI
func tr(_ text: String) -> String { text }
enum KKColor { static let textSecondary = Color.secondary }
SWIFT
swiftc -typecheck -swift-version 5 Sources/Kikishima/CopyFeedback.swift Sources/Kikishima/CopyFeedbackView.swift "$KK_TEST_TMP_ROOT/UIStubs.swift"
