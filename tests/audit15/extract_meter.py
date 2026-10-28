"""Compile the actual AudioMeter declaration without the app's UI dependencies.
No copied implementation or replacement meter is used. Refuse an ambiguous source.
Stage B may move the unchanged public interface to AudioMeter.swift.
"""
from pathlib import Path
import re
import sys
standalone = Path("Sources/Kikishima/AudioMeter.swift")
if standalone.exists():
    Path(sys.argv[1]).write_text(standalone.read_text())
else:
    src = Path("Sources/Kikishima/CaptionState.swift").read_text()
    match = re.search(r"^final class AudioMeter\b", src, re.M)
    if not match:
        raise SystemExit("audit15: AudioMeter declaration not found; update test entry for its new location")
    # Current declaration has no braces in strings. Balance braces to include the full class.
    start = src.index("{", match.start())
    depth = 1
    end = start + 1
    while depth and end < len(src):
        depth += (src[end] == "{") - (src[end] == "}")
        end += 1
    if depth:
        raise SystemExit("audit15: incomplete AudioMeter declaration")
    Path(sys.argv[1]).write_text("import Foundation\nimport AVFoundation\nimport AudioToolbox\n" + src[match.start():end] + "\n")
