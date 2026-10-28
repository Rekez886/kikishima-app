#!/usr/bin/env python3
"""Check UI language persistence without constructing application state."""

from pathlib import Path
import re
import sys


def main():
    root = Path(__file__).resolve().parents[2]
    source = root / "Sources/Kikishima/CaptionState.swift"
    text = source.read_text(encoding="utf-8")
    # Match the actual property and its entire didSet, allowing whitespace edits.
    pattern = (
        r'\bvar\s+uiLanguage\s*:\s*String\s*=\s*'
        r'UserDefaults\s*\.\s*standard\s*\.\s*string\s*\(\s*'
        r'forKey\s*:\s*"uiLanguage"\s*\)\s*\?\?\s*""\s*\{\s*'
        r'didSet\s*\{\s*AppLanguagePreference\s*\.\s*persist\s*'
        r'\(\s*uiLanguage\s*\)\s*\}\s*\}'
    )
    if not re.search(pattern, text):
        print("FAIL: CaptionState.uiLanguage must persist through AppLanguagePreference", file=sys.stderr)
        return 1
    print("PASS: UI language persistence wiring")
    return 0


if __name__ == "__main__":
    sys.exit(main())
